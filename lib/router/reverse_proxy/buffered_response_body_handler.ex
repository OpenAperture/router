defmodule OpenAperture.Router.ReverseProxy.BufferedResponseBodyHandler do
  @moduledoc """
  This module contains the handler for processing buffered response bodies.
  """

  alias OpenAperture.Router.ReverseProxy.Client
  alias OpenAperture.Router.Types

  # Read the timeouts info from the env config
  @timeouts Application.get_env(:openaperture_router, :timeouts, [
    connecting:            5_000,
    sending_request_body:  60_000,
    waiting_for_response:  60_000,
    receiving_response:    60_000
    ])
  # TODO: this seems redundant with the version in chunked. Pull up somewhere?

  @doc """
  Handles buffering the entire response body from the backend server before
  sending the reply, containing the status, headers, and response body on to
  the client.
  """
  @spec handle(Types.cowboy_req, pid, String.t, Types.headers, [String.t]) :: {:ok | :error, Types.cowboy_req, Types.microseconds} | {:error, :timeout}
  def handle(req, backend_request_server_pid, status_line, response_headers, chunks \\ []) do
    timeout = Keyword.get(@timeouts, :receiving_response, 5_000)
    receive do
      {:backend_request_error, ^backend_request_server_pid, _reason, backend_duration} ->
        # Todo: See if we can glean some information from the `reason` param
        # which might allow us to set a more helpful status code.
        {:error, req, backend_duration}

      {:backend_request_response_chunk, ^backend_request_server_pid, chunk} ->
        # Recursively loop back into this handler until we're done.
        handle(req, backend_request_server_pid, status_line, response_headers, [chunk] ++ chunks)

      {:backend_request_done, ^backend_request_server_pid, backend_duration} ->
        # We've buffed the whole response, so now we're ready to reply to
        # the client
        body = chunks
               |> Enum.reverse
               |> Enum.join

        {req, reply_time} = Client.send_reply(req, status_line, response_headers, body)

        {:ok, req, backend_duration + reply_time}

    after timeout ->
      {:error, :timeout}
    end
  end
end
