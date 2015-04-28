defmodule OpenAperture.Router.ReverseProxy do
  require Logger

  import OpenAperture.Router.HttpRequestUtil

  alias OpenAperture.Router.BackendRequestServer

  @type cowboy_req :: tuple
  @type headers :: [{String.t, String.t}]

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
  @spec proxy_request(cowboy_req, String.t, atom) :: {atom, cowboy_req, integer}
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

    case get_route_for_host(host, port, path) do
      nil ->
        # There aren't any routes defined for this host, so just bail.
        {:ok, req} = :cowboy_req.reply(503, req)
        {:ok, req, 0}
      {backend_host, backend_port, is_https} ->
        {method, req} = get_request_method(req)
        {headers, req} = :cowboy_req.headers(req)

        # Add any custom headers needed...
        {headers, req} = add_router_headers(headers, host, port, req, protocol)

        {url, req} = get_backend_url(req, backend_host, backend_port, is_https)

        # Start performing the backend request in a separate process
        {:ok, backend_request_server_pid} = GenServer.start(BackendRequestServer, self)

        has_body = Enum.any?(headers, fn {header, _value} ->
          header = String.downcase(header)
          header == "content-length" || header == "transfer-encoding"
        end)

        result = BackendRequestServer.start_request(backend_request_server_pid, method, url, headers, has_body)
        case result do
          {:error, reason, request_time} ->
            Logger.error "An error occurred initiating the request to #{url}: #{inspect reason}"
            # TODO: Maybe retry the request?
            {_reply_time, {result, req}} = :timer.tc(:cowboy_req, :reply, [503, [], "", req])
            {result, req, request_time}
          {:ok, request_time} ->
            if has_body do
              # We need to send the request body
              case send_body(req, backend_request_server_pid) do
                {:ok, req, send_body_time} ->
                  message_loop(req, backend_request_server_pid, :waiting_for_response, request_time + send_body_time)
                {:error, reason, req, send_body_time} ->
                  {:error, reason, req, request_time}
              end
            else
              message_loop(req, backend_request_server_pid, :waiting_for_response, request_time)
            end
        end
    end
  end

  @spec send_body(cowboy_req, pid, integer) :: {:ok, cowboy_req, integer} | {:error, any, cowboy_req, integer}
  defp send_body(req, backend_request_server_pid, time \\ 0) do
    {req_time, result} = :timer.tc(:cowboy_req, :body, [req, [length: 4096, read_length: 4096]])
    case result do
       {:error, reason} ->
        Logger.error "Error retrieving request body: #{inspect reason}"
        {:error, reason, req, time}

      {:more, chunk, req} ->
        case BackendRequestServer.send_request_chunk(backend_request_server_pid, chunk, false) do
          {:ok, send_chunk_time} ->
            send_body(req, backend_request_server_pid, time + req_time + send_chunk_time)
          {:error, reason, send_chunk_time} ->
            Logger.error "Error sending request body chunk to backend server: #{inspect reason}"
            # TODO: Retry?
            {:error, reason, req, time + req_time + send_chunk_time}
        end
      {:ok, chunk, req} ->
        case BackendRequestServer.send_request_chunk(backend_request_server_pid, chunk, true) do
          {:ok, send_chunk_time} ->
            {:ok, req, time + req_time + send_chunk_time}
          {:error, reason, send_chunk_time} ->
            Logger.error "Error sending *final* request body chunk to backend server: #{inspect reason}"
            {:error, reason, req, time + req_time + send_chunk_time}
        end
    end
  end

  # Message Loop stages:
  # :waiting_for_response
  # :receiving_response
  @spec message_loop(cowboy_req, pid, atom, integer, Map.t) :: {:ok, cowboy_req, integer} | {:error, cowboy_req, integer}
  defp message_loop(req, backend_request_pid, stage, duration, state \\ %{}) do
    timeout = Keyword.get(@timeouts, stage, 5_000)

    receive do
      {:backend_request_error, ^backend_request_pid, _reason} ->
        # Todo: See if we can glean some information from the `reason` param
        # which might allow us to set a more helpful status code.
        # TODO: fix time
        {:error, req, duration}

      {:backend_request_initial_response, ^backend_request_pid, status_code, status_reason, response_headers} ->
        if chunked_request?(response_headers) do
          status = get_response_status(status_code, status_reason)
          {reply_time, {:ok, req}} = :timer.tc(:cowboy_req, :chunked_reply, [status, response_headers, req])
          state = Map.put(state, :response_type, :chunked)
          message_loop(req, backend_request_pid, :receiving_response, duration + reply_time, state)
        else
          # WORKAROUND:
          # Hackney will hang waiting for a response body even if the server
          # responds with a status code which indicates there won't be a
          # response body (i.e. 204, 304). If we get one of these response
          # statuses, and there's no content-length or transfer-encoding
          # header, just reply to the client and kill the backend process.
          if status_code in [204, 304] && get_content_length_or_transfer_encoding(response_headers) do
            # We're done here. Reply to the client and kill the
            # backend request process.
            status = get_response_status(status_code, status_reason)
            {reply_time, {result, req}} = :timer.tc(:cowboy_req, :reply, [status, response_headers, "", req])
            Process.unlink(backend_request_pid)
            Process.exit(backend_request_pid, :normal)
            {result, req, duration + reply_time}
          else
            # Otherwise, we need to buffer or stream the response body
            # TODO: Determine if we can buffer the response, or if we need to
            # just stream it. For now we just buffer the whole response
            state = Map.merge(state, %{
              response_type: :buffered,
              status_code: status_code,
              status_reason: status_reason,
              response_headers: response_headers,
              chunks: []})
            message_loop(req, backend_request_pid, :receiving_response, duration, state)
          end
        end

      {:backend_request_response_chunk, ^backend_request_pid, chunk} ->
        case state[:response_type] do
          :chunked ->
            {_result, send_time} = send_response_body_chunk(req, chunk)
            message_loop(req, backend_request_pid, :receiving_response, duration + send_time, state)
          :buffered ->
            chunks = [chunk] ++ state[:chunks]
            state = Map.put(state, :chunks, chunks)
            message_loop(req, backend_request_pid, :receiving_response, duration, state)
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

            status = get_response_status(state)
            {reply_time, {result, req}} = :timer.tc(:cowboy_req, :reply, [status, state[:response_headers], body, req])

            # TODO: Fix time
            {result, req, backend_duration}#duration + backend_duration + reply_time}
          # TODO: streaming
          # :streaming ->
        end

      after timeout ->
        Logger.error "Reverse proxy timed out after #{inspect timeout}ms on stage: #{inspect stage}"
        {:error, req, 0}
    end
  end

  # Send the chunk from the backend server down to the client
  @spec send_response_body_chunk(cowboy_req, String.t) :: {:ok, integer} | {:error, integer}
  defp send_response_body_chunk(req, chunk) do
    {time, result} = :timer.tc(:cowboy_req, :chunk, [chunk, req])
    case result do
      :ok -> {:ok, time}
      {:error, reason} ->
        Logger.error "Error sending chunk to client: #{inspect reason}"
        {:error, time}
    end
  end

  # Retrieves a status code plus a custom status reason message, if a custom
  # reason is provided from the backend server.
  @spec get_response_status(Map.t) :: String.t
  defp get_response_status(%{status_code: status_code} = state) do
    if Map.has_key?(state, :status_reason) do
      get_response_status(status_code, state[:status_reason])
    else
      Integer.to_string(status_code)
    end
  end

  @spec get_response_status(integer, String.t) :: String.t
  defp get_response_status(status_code, status_reason) do
    if status_reason != nil && String.length(status_reason) > 0 do
      "#{status_code} #{status_reason}"
    else
      Integer.to_string(status_code)
    end
  end

  @spec get_route_for_host(String.t, integer, String.t) :: {String.t, integer, boolean}
  defp get_route_for_host(host, port, _path) do
    # For now we'll just randomly pick a backend route to route to...
    routes = ConCache.get(:routes, "#{host}:#{port}")
    Logger.debug "Routes matching #{host}:#{port}: #{inspect routes}"

    case routes do
      nil -> nil
      [route | []] -> route
      routes ->
        index = :random.uniform(length(routes)) - 1
        Enum.at(routes, index)
    end
  end

  # Returns {headers, req}
  @spec add_router_headers(headers, String.t, integer, cowboy_req, atom) :: {headers, cowboy_req}
  defp add_router_headers(headers, host, port, req, proto) when is_list(headers) do
    x_openaperture_request_id_header = List.keyfind(headers, "x-openaperture-request-id", 0)
    x_forwarded_for_header = List.keyfind(headers, "x-forwarded-for", 0)
    x_forwarded_host_header = List.keyfind(headers, "x-forwarded-host", 0)
    x_forwarded_port_header = List.keyfind(headers, "x-forwarded-port", 0)
    x_forwarded_proto_header = List.keyfind(headers, "x-forwarded-proto", 0)

    headers = if x_openaperture_request_id_header == nil, do: add_request_id_header(headers), else: headers
    {headers, req} = if x_forwarded_for_header == nil, do: add_forwarded_for_header(headers, req), else: {headers, req}
    headers = if x_forwarded_host_header == nil, do: add_forwarded_host_header(headers, host), else: headers
    headers = if x_forwarded_port_header == nil, do: add_forwarded_port_header(headers, port), else: headers
    headers = if x_forwarded_proto_header == nil, do: add_forwarded_proto_header(headers, proto), else: headers

    {headers, req}
  end

  @spec add_request_id_header(headers) :: headers
  defp add_request_id_header(headers) do
    request_id = UUID.uuid4(:hex)
    [{"X-OpenAperture-Request-ID", request_id}] ++ headers
  end

  @spec add_forwarded_for_header(headers, cowboy_req) :: {headers, cowboy_req}
  defp add_forwarded_for_header(headers, req) do
    {{peer_addr, peer_port}, req} = :cowboy_req.peer(req)

    address_header = case :inet.ntoa(peer_addr) do
      {:error, reason} ->
        Logger.error "Couldn't convert peer_addr #{inspect peer_addr} into address string. Reason: #{inspect reason}"
        # "unknown" is the correct identifier to pass in this case, per RFC 7239
        # (http://tools.ietf.org/html/rfc7239#section-6)
        "unknown"
      addr ->
        "#{addr}:#{peer_port}"
    end

    {[{"X-Forwarded-For", address_header}] ++ headers, req}
  end

  @spec add_forwarded_host_header(headers, String.t) :: headers
  defp add_forwarded_host_header(headers, host) do
    [{"X-Forwarded-Host", host}] ++ headers
  end

  @spec add_forwarded_port_header(headers, integer) :: headers
  defp add_forwarded_port_header(headers, port) do
    [{"X-Forwarded-Port", Integer.to_string(port)}] ++ headers
  end

  @spec add_forwarded_proto_header(headers, atom) :: headers
  defp add_forwarded_proto_header(headers, proto) do
    [{"X-Forwarded-Proto", Atom.to_string(proto)}] ++ headers
  end
end