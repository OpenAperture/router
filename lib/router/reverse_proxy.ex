defmodule OpenAperture.Router.ReverseProxy do
  require Logger

  import OpenAperture.Router.HttpRequestUtil

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
    # backed), send us messages whenever it gets data from the backend, so that
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
        backend_request_pid = spawn(OpenAperture.Router.BackendRequest, :make_request, [self, method, url, headers])

        # Start listening for messages from our backend request
        message_loop(req, backend_request_pid, :connecting)
    end
  end

  # Message Loop stages:
  # :connecting
  # :sending_request_body
  # :waiting_for_response
  # :receiving_response
  defp message_loop(req, backend_request_pid, stage, state \\ %{}) do
    timeout = Keyword.get(@timeouts, stage, 5_000)

    receive do
      {:error, ^backend_request_pid, _reason, time} ->
        # Todo: See if we can glean some information from the `reason` param
        # which might allow us to set a more helpful status code.
        {:error, req, time}

      {:connected, ^backend_request_pid, send_body} ->
        # The backend request process has initiated a request with the backend
        # server, so now we need to either wait for a response or start
        # streaming request body data.
        if send_body do
          case send_request_body_chunk(req, backend_request_pid) do
            {:error, _reason, req, send_time} ->
              # Todo: process error
              {:error, req, send_time}
            {:ok, req, _send_time} ->
              # Loop, we'll either get messages requesting more body data or
              # a message indicating we should start sending a response
              message_loop(req, backend_request_pid, :sending_request_body)
          end
        else
          # No request body needs to be sent, so just wait for a response
          message_loop(req, backend_request_pid, :waiting_for_response)
        end

      {:ready_for_body, ^backend_request_pid} ->
        # The backend request process has sent the previous chunk and is
        # ready to send more
        case send_request_body_chunk(req, backend_request_pid) do
          {:error, _reason, req, send_time} ->
            # Todo: process error
            {:error, req, send_time}
          {:ok, req, _send_time} ->
            # Loop, we'll either get messages requesting more body data or
            # message indicating we're waiting for the response from the
            # backend server.
            message_loop(req, backend_request_pid, :sending_request_body)
        end

      {:waiting_for_response, ^backend_request_pid} ->
        message_loop(req, backend_request_pid, :waiting_for_response)

      {:initial_response, ^backend_request_pid, {status_code, status_reason, response_headers}, time} ->
        if chunked_request?(response_headers) do
          status = get_response_status(status_code, status_reason)
          {_reply_time, {:ok, req}} = :timer.tc(:cowboy_req, :chunked_reply, [status, response_headers, req])
          state = Map.put(state, :response_type, :chunked)
          message_loop(req, backend_request_pid, :receiving_response, state)
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
            {_reply_time, {result, req}} = :timer.tc(:cowboy_req, :reply, [status, response_headers, "", req])
            Process.unlink(backend_request_pid)
            Process.exit(backend_request_pid, :normal)
            {result, req, time}
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
            message_loop(req, backend_request_pid, :receiving_response, state)
          end
        end

      {:response_chunk, ^backend_request_pid, chunk} ->
        case state[:response_type] do
          :chunked ->
            {_result, _send_time} = send_response_body_chunk(req, chunk)
            message_loop(req, backend_request_pid, :receiving_response, state)
          :buffered ->
            # TODO: Prepend the new chunk, and then do a single Enum.reverse on
            # the list of chunks before we send it back. Appending to the end
            # of a list is slow!
            chunks = state[:chunks] ++ [chunk]
            state = Map.put(state, :chunks, chunks)
            message_loop(req, backend_request_pid, :receiving_response, state)
          # TODO: streaming
          # :streaming ->
            # stream the response body

        end

      {:response_done, ^backend_request_pid, time} ->
        case state[:response_type] do
          :chunked ->
            # Cowboy should close the connection for us, so all we should need
            # to do here is return, closing out the message loop.
            {:ok, req, time}
          :buffered ->
            # We've buffed the whole response, so now we're ready to reply to
            # the client
            body = Enum.join(state[:chunks])

            status = get_response_status(state)
            {_reply_time, {result, req}} = :timer.tc(:cowboy_req, :reply, [status, state[:response_headers], body, req])

            {result, req, time}
          # TODO: streaming
          # :streaming ->
        end

      after timeout ->
        Logger.error "Reverse proxy timed out after #{inspect timeout}ms on stage: #{inspect stage}"
        {:error, req, 0}
    end
  end

  # Broken out into a separate function to keep the message loop tidy
  # Returns {:ok, req} | {:error, reason, req}
  defp send_request_body_chunk(req, backend_request_pid) do
    {time, result} = :timer.tc(:cowboy_req, :body, [req, [length: 4096, read_length: 4096]])
    case result do
      {:error, reason} ->
        Logger.error "Error retrieving request body: #{inspect reason}"
        {:error, reason, req, time}

      {:more, chunk, req} ->
        send(backend_request_pid, {:request_body_chunk, self, chunk})
        {:ok, req, time}

      {:ok, chunk, req} ->
        send(backend_request_pid, {:final_body_chunk, self, chunk})
        {:ok, req, time}
    end
  end

  # Send the chunk from the backend server down to the client
  # Returns :ok | {:error, reason}
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
  defp get_response_status(%{status_code: status_code} = state) do
    if Map.has_key?(state, :status_reason) do
      get_response_status(status_code, state[:status_reason])
    else
      status_code
    end
  end

  defp get_response_status(status_code, status_reason) do
    if status_reason != nil && String.length(status_reason) > 0 do
      "#{status_code} #{status_reason}"
    else
      status_code
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
    headers ++ [{"X-OpenAperture-Request-ID", request_id}]
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

    {headers ++ [{"X-Forwarded-For", address_header}], req}
  end

  @spec add_forwarded_host_header(headers, String.t) :: headers
  defp add_forwarded_host_header(headers, host) do
    headers ++ [{"X-Forwarded-Host", host}]
  end

  @spec add_forwarded_port_header(headers, integer) :: headers
  defp add_forwarded_port_header(headers, port) do
    headers ++ [{"X-Forwarded-Port", Integer.to_string(port)}]
  end

  @spec add_forwarded_proto_header(headers, atom) :: headers
  defp add_forwarded_proto_header(headers, proto) do
    headers ++ [{"X-Forwarded-Proto", Atom.to_string(proto)}]
  end
end