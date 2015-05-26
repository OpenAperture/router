defmodule OpenAperture.Router.ReverseProxy do
  require Logger

  import OpenAperture.Router.HttpRequestUtil
  import OpenAperture.Router.ReverseProxy.Backend
  import OpenAperture.Router.ReverseProxy.Client

  alias OpenAperture.Router.ReverseProxy.BufferedResponseBodyHandler
  alias OpenAperture.Router.ReverseProxy.ChunkedResponseBodyHandler
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
  @spec proxy_request(Types.cowboy_req, String.t, atom) :: {:ok | :error, Types.cowboy_req, integer}
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
        {req, _reply_time} = send_reply(req, "503 Service Unavailable", [], "")
        {:ok, req, 0}
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
              handle_response(req, backend_request_server_pid)
            {:error, reason, req, send_body_time} ->
              {:error, reason, req, request_time + send_body_time}
          end
        else
          handle_response(req, backend_request_server_pid)
        end
    end
  end

  @spec handle_response(Types.cowboy_req, pid) :: {:ok, Types.cowboy_req, integer} | {:error, Types.cowboy_req, integer}
  defp handle_response(req, backend_request_server_pid) do
    case wait_for_response(req, backend_request_server_pid) do
      :timeout ->
        {:error, req, 0}
      {:replied, req, duration} ->
        {:ok, req, duration}
      {:initial_response, status_code, status_reason, response_headers, backend_duration} ->
        status_line = get_response_status(status_code, status_reason)

        if chunked_request?(response_headers) do
          req = :cowboy_req.set_meta(:response_type, :chunked, req)
          {req, _reply_time} = start_chunked_reply(req, status_line, response_headers)
          ChunkedResponseBodyHandler.handle(req, backend_request_server_pid)
        else
          response_headers
          |> get_content_length_header
          |> parse_content_length_header
          |> case do
            len when is_integer(len) and len < 102_400 ->
              req = :cowboy_req.set_meta(:response_type, :buffered, req)
              BufferedResponseBodyHandler.handle(req, backend_request_server_pid, status_line, response_headers)
            _ ->
              # Handling the streaming response is done in two parts. Here, we
              # initiate the reply, with our custom request object metadata of
              # `:response_type` set to `:streaming`. In 
              # `HttpHandler.onresponse/4`, we'll check that metadata, see that
              # it's set to `:streaming`, and call the streaming response body
              # handler.
              req = :cowboy_req.set_meta(:response_type, :streaming, req)
              {req, reply_time} = send_reply(req, status_line, response_headers)
              {:ok, req, reply_time + backend_duration}
          end
        end
    end
  end

  defp wait_for_response(req, backend_request_server_pid) do
    timeout = Keyword.get(@timeouts, :waiting_for_response, 5_000)
    receive do
      {:backend_request_error, ^backend_request_server_pid, _reason, backend_duration} ->
        # Todo: See if we can glean some information from the `reason` param
        # which might allow us to set a more helpful status code.
        {:error, req, backend_duration}

      {:backend_request_initial_response, ^backend_request_server_pid, status_code, status_reason, response_headers, backend_duration} ->
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
          {req, reply_time} = send_reply(req, status_line, response_headers, "")
          Process.unlink(backend_request_server_pid)
          Process.exit(backend_request_server_pid, :normal)
          {:replied, req, backend_duration + reply_time}
        else
          {:initial_response, status_code, status_reason, response_headers, backend_duration}
        end

    after timeout ->
      Logger.error "Reverse proxy timed out after #{inspect timeout}ms while waiting for an initial response from the backend server."
      :timeout
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