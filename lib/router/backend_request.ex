defmodule OpenAperture.Router.BackendRequest do
  @moduledoc """
  BackendRequest handles issuing the proxied request to the backend server,
  streaming the original request body from the client to the backend server,
  and streaming the response from the backend to the client.

  This is also where we (attempt) to deal with all the craziness that is
  involved in working with HTTP clients and servers, none of whom seem to 
  implement the HTTP spec in the same way. In other words: here be dragons.
  """
  require Logger

  import OpenAperture.Router.Util

  @type headers :: [{String.t, String.t}]

  @doc """
  make_request should be started in a new process (via `spawn` or a similar
  mechanism), as it expects to receive the pid of the spawning process as an
  argument. As the client request is streamed from the client to the router,
  the spawning process will send messages containing request data to this
  process, and as the response is streamed from the backend server to the
  router, this function will send messages to the spawning process indicating
  progress, including response data. Then the spawning process can stream 
  response data back to the client.
  Additionally, the spawning process can timeout after an interval if the
  backend request is taking too long to complete.
  """
  @spec make_request(pid, atom, String.t, headers) :: none
  def make_request(parent_pid, method, url, headers) do
    response_handler_pid = spawn_link(OpenAperture.Router.ResponseHandler, :init, [self])
    hackney_options = [:async, {:stream_to, response_handler_pid}]
    hackney_options = hackney_options ++ get_hackney_options(url)

    has_body = Enum.any?(headers, fn {header, _value} ->
      header = String.downcase(header)
      header == "content-length" || header == "transfer-encoding"
    end)

    send(response_handler_pid, {:reset_timer, self})
    {time, result} = if has_body do
      :timer.tc(:hackney, :request, [method, url, headers, :stream, hackney_options])
    else
      :timer.tc(:hackney, :request, [method, url, headers, "", hackney_options])
    end

    # Subtract `time` from the above timer call from the current timestamp to
    # get an estimate of when the call started.
    timestamp = :erlang.now
                |> erlang_timestamp_to_integer
                |> (fn x -> x - time end).()
                |> integer_to_erlang_timestamp

    case result do
      {:ok, client} ->
        # Tell our parent process that we've connected to the backend server,
        # so it should start sending us messages streaming the request body
        # (if applicable), or wait for a response
        send(parent_pid, {:connected, self, has_body})

        # Start listening for messages
        message_loop(parent_pid, client, response_handler_pid, url, timestamp)
      {:error, reason} ->
        Logger.error "Error initiating request to backend server at #{get_authority_from_url(url)}: #{inspect reason}"
        Process.unlink(response_handler_pid)
        Process.exit(response_handler_pid, :normal)
        send(parent_pid, {:error, self, reason, time})
    end
  end

  # The internal message loop for the backend request process. This function
  # handles receiving messages from both the parent process and child
  # processes, and calls back into itself recursively until either an error
  # occurs, or the complete backend response has been processed.
  defp message_loop(parent_pid, client, response_handler_pid, url, start_time) do
    receive do
      # :request_body_chunk is a message sent by the parent process, containing
      # the next chunk of client request data.
      {:request_body_chunk, ^parent_pid, chunk} ->
        case :hackney.send_body(client, chunk) do
          {:error, reason} ->
            Logger.error "Error sending request body chunk to backend server at #{get_authority_from_url(url)}: #{inspect reason}"
            send(parent_pid, {:error, self, reason, :timer.now_diff(:erlang.now(), start_time)})
          :ok ->
            # request more body chunks
            send(parent_pid, {:ready_for_body, self})
            message_loop(parent_pid, client, response_handler_pid, url, start_time)
        end
      
      # :final_body_chunk is a message sent by the parent process, containing
      # the last (or only) chunk of request body data. After this message, we
      # have received all request data, so we can start listening for a
      # response from the backend server.
      {:final_body_chunk, ^parent_pid, chunk} ->
        case :hackney.send_body(client, chunk) do
          {:error, reason} ->
            Logger.error "Error sending FINAL request body chunk to backend server at #{get_authority_from_url(url)}: #{inspect reason}"
            send(parent_pid, {:error, self, reason, :timer.now_diff(:erlang.now(), start_time)})
          :ok ->
            # That was the last chunk, let's get the response.
            case :hackney.start_response(client) do
              {:error, reason} ->
                Logger.error "Error starting to wait for response from backend server at #{get_authority_from_url(url)}: #{inspect reason}"
                send(parent_pid, {:error, self, reason, :timer.now_diff(:erlang.now(), start_time)})
                Process.unlink(response_handler_pid)
                Process.exit(response_handler_pid, :normal)
              {:ok, client} ->
                send(parent_pid, {:waiting_for_response, self})
                message_loop(parent_pid, client, response_handler_pid, url, start_time)
            end
        end

      # :response_error is a message sent by the response handler process,
      # indicating that it has encountered an error while processing the
      # response from the backend server.
      {:response_error, ^response_handler_pid, reason} ->
        send(parent_pid, {:error, self, reason, :timer.now_diff(:erlang.now(), start_time)})

      # :response_got_initial_response is a message sent by the response
      # handler process, indicating it received an intial response
      # (status code and response headers) from the backend server.
      {:response_got_initial_response, ^response_handler_pid, response} ->
        send(parent_pid, {:initial_response, self, response, :timer.now_diff(:erlang.now(), start_time)})
        message_loop(parent_pid, client, response_handler_pid, url, start_time)

      # :got_response_chunk is a message sent by the response handler process,
      # containg a chunk of response body data from the backend server.
      {:got_response_chunk, ^response_handler_pid, chunk} ->
        send(parent_pid, {:response_chunk, self, chunk})
        message_loop(parent_pid, client, response_handler_pid, url, start_time)

      # :got_response_done is a message sent by the response handler process,
      # indicating it has procesed the entire response from the backend server.
      {:got_response_done, ^response_handler_pid} ->
        send(parent_pid, {:response_done, self, :timer.now_diff(:erlang.now(), start_time)})
      
      # a catch-all message handler for unexpected messages.
      other ->
        Logger.error "backend_request received an unexpected message: #{inspect other}"
        message_loop(parent_pid, client, response_handler_pid, url, start_time)
    end
  end
end