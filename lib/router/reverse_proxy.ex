defmodule OpenAperture.Router.ReverseProxy do
  require Logger

  import OpenAperture.Router.HttpRequestUtil
  import OpenAperture.Router.ReverseProxy.Backend
  import OpenAperture.Router.ReverseProxy.Client

  alias OpenAperture.Router.RouteCache
  alias OpenAperture.Router.Types

  # Read the timeouts info from the env config
  @timeouts Application.get_env(:openaperture_router, :timeouts, [
    connecting: 5_000,
    sending_request_body: 60_000,
    waiting_for_response: 60_000,
    receiving_response: 60_000
    ])

  @doc """
  `proxy_request` handles reading request data from the incoming client
  request, sending it on to a backend server, reading response data from the
  backend server, and sending it back to the client.

  Returns a tuple containing an atom (like :ok or :error), the `cowboy_req`
  object, and an integer indicating the duration of the backend request
  (in microseconds).
  """
  @spec proxy_request(Types.cowboy_req, String.t, atom) :: {atom, Types.cowboy_req, integer}
  def proxy_request(req, path, protocol) do
    # Issue the request to the backend server in a different process, as
    # cowboy sends messages to the current process, which we don't want to
    # handle.

    # We can't, hoever, process parts of the client request (using the
    # :cowboy_req module), in that other process, as the cowboy documentation
    # states:
    # "It is highly discouraged to pass the Req object to another process. 
    # Doing so and calling `cowboy_req` functions from it leads to undefined
    # behavior." (http://ninenines.eu/docs/en/cowboy/1.0/manual/cowboy_req/)
    #
    # So, we need to have the child process (which handles connecting to the
    # backend), send us messages whenever it gets data from the backend, so that
    # we can turn around and send that data to the client.
    {host, req} = :cowboy_req.host(req)
    {port, req} = :cowboy_req.port(req)

    case RouteCache.get_route_for_authority(host, port, path) do
      nil ->
        # There aren't any routes defined for this host, so just bail.
        {result, req, _reply_time} = send_reply(req, "503", [], "")
        {result, req, 0}
      {backend_host, backend_port, is_https} ->
        {method, req} = get_request_method(req)
        {headers, req} = :cowboy_req.headers(req)

        # Add any custom headers needed...
        {headers, req} = add_router_request_headers(headers, host, port, req, protocol)

        proxy_request(method, req, backend_host, backend_port, is_https, headers)
    end
  end

  @spec proxy_request(atom, Types.cowboy_req, String.t, integer, boolean, Types.headers) :: {:ok, Types.cowboy_req, Types.microseconds} | {:error, any, Types.cowboy_req, Types.microseconds}
  def proxy_request(method, req, host, port, is_https, headers) do
    {url, req} = get_backend_url(req, host, port, is_https)

    has_body = Enum.any?(headers, fn {header, _value} ->
      header = String.downcase(header)
      header == "content-length" || header == "transfer-encoding"
    end)

    # Start performing the backend request in a separate process
    case start_request(method, url, headers, has_body) do
      {:error, _reason, request_time} ->
        # TODO: Quarantine and retry functionality
        {_reply_time, {result, req}} = :timer.tc(:cowboy_req, :reply, [503, [], "", req])
        {result, req, request_time}
      {:ok, backend_request_server_pid, request_time} ->
        if has_body do
          # We need to send the request body
          case send_request_body(req, backend_request_server_pid) do
            {:ok, req, _send_body_time} ->
              message_loop(req, backend_request_server_pid, :waiting_for_response)
            {:error, reason, req, send_body_time} ->
              {:error, reason, req, request_time + send_body_time}
          end
        else
          message_loop(req, backend_request_server_pid, :waiting_for_response)
        end
    end
  end

  # Message Loop stages:
  # :waiting_for_response
  # :receiving_response
  @spec message_loop(Types.cowboy_req, pid, atom,  Map.t) :: {:ok, Types.cowboy_req, integer} | {:error, Types.cowboy_req, integer}
  defp message_loop(req, backend_request_pid, stage, state \\ %{}) do
    timeout = Keyword.get(@timeouts, stage, 5_000)

    receive do
      {:backend_request_error, ^backend_request_pid, _reason, backend_duration} ->
        # Todo: See if we can glean some information from the `reason` param
        # which might allow us to set a more helpful status code.
        {:error, req, backend_duration}

      {:backend_request_initial_response, ^backend_request_pid, status_code, status_reason, response_headers, backend_duration} ->
        status_line = get_response_status(status_code, status_reason)

        # WORKAROUND:
        # Hackney will hang waiting for a response body even if the server
        # responds with a status code which indicates there won't be a
        # response body (i.e. 204, 304). If we get one of these response
        # statuses, and there's no content-length or transfer-encoding
        # header, just reply to the client and kill the backend process.
        if status_code in [204, 304] && !get_content_length_or_transfer_encoding(response_headers) do
          # We're done here. Reply to the client and kill the
          # backend request process.
          {result, req, reply_time} = send_reply(req, status_line, response_headers, "")
          Process.unlink(backend_request_pid)
          Process.exit(backend_request_pid, :normal)
          {result, req, backend_duration + reply_time}
        else
          state = Map.merge(state, %{
          status_code: status_code,
          status_reason: status_reason,
          status_line: status_line,
          response_headers: response_headers
          })

          state = if chunked_request?(response_headers) do
            {result, req, reply_time} = start_chunked_reply(req, status_line, response_headers)
            Map.merge(state, %{response_type: :chunked})
          else
            Map.merge(state, %{response_type: :buffered, chunks: []})
          end

          message_loop(req, backend_request_pid, :receiving_response, state)
        end

      {:backend_request_response_chunk, ^backend_request_pid, chunk} ->
        case state[:response_type] do
          :chunked ->
            {_result, _send_time} = send_response_body_chunk(req, chunk)
            message_loop(req, backend_request_pid, :receiving_response, state)
          :buffered ->
            message_loop(req, backend_request_pid, :receiving_response, %{state | chunks: [chunk] ++ state[:chunks]})
          # TODO: streaming
          # :streaming ->
            # stream the response body

        end

      {:backend_request_done, ^backend_request_pid, backend_duration} ->
        case state[:response_type] do
          :chunked ->
            # Cowboy should close the connection for us, so all we should need
            # to do here is return, closing out the message loop.
            # TODO: Fix time
            {:ok, req, backend_duration}#duration + backend_duration}
          :buffered ->
            # We've buffed the whole response, so now we're ready to reply to
            # the client
            body = state[:chunks]
                   |> Enum.reverse
                   |> Enum.join

            {result, req, reply_time} = send_reply(req, state[:status_line], state[:response_headers], body)

            {result, req, backend_duration + reply_time}

          # TODO: streaming
          # :streaming ->
        end

      after timeout ->
        Logger.error "Reverse proxy timed out after #{inspect timeout}ms on stage: #{inspect stage}"
        {:error, req, 0}
    end
  end

  # Retrieves a status code plus a custom status reason message, if a custom
  # reason is provided from the backend server.
  @spec get_response_status(integer, String.t) :: String.t
  defp get_response_status(status_code, status_reason) do
    if status_reason != nil && String.length(status_reason) > 0 do
      "#{status_code} #{status_reason}"
    else
      Integer.to_string(status_code)
    end
  end
end