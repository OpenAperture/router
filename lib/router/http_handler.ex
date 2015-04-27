defmodule OpenAperture.Router.HttpHandler do
  require Logger

  import OpenAperture.Router.HttpRequestUtil
  import OpenAperture.Router.Util
  alias OpenAperture.Router.ReverseProxy

  # We set the on_response handler to allow us to strip out any response
  # headers cowboy may set automatically, since we want the router to be
  # transparent to the client.
  def on_response(status, headers, body, req) do
    # Cowboy inserts its own connection, date, server, and transfer-encoding
    # headers if the backend server has capitalized those headers. So we would
    # end up sending responses with responsed headers like:
    # "server: Cowboy, Server: nginx".
    # Cowboy also prepends its version of the header, so we just need to
    # reverse the list of headers and do a case-insensitive unique filter to
    # strip out any Cowboy-specific version of a response header.
    headers = headers
              |> Enum.reverse
              |> Enum.uniq(fn {header, _value} -> String.downcase(header) end)

    try do
      {:ok, req} = if chunked_request?(headers) do
        :cowboy_req.chunked_reply(status, headers, req)
      else
        # TODO: Figure out if we're sending back a buffered response or if we
        # should be streaming the response... For now, we'll send it buffered.
        :cowboy_req.reply(status, headers, body, req)
      end

      req
    catch
      _any ->
        # Per the cowboy documentation, this on_response handler *must not* be
        # allowed to crash, so let's just return the req here and hope for the
        # best. ¯\_(ツ)_/¯
        req
    end
  end

  ### Cowboy Handler callbacks ###

  # init is called by cowboy when first beginning to handle a new request. We
  # use it to record the timestamp of when we first received the request
  def init({transport, _proto_name}, req, _opts) do
    start_time = :os.timestamp()

    {:ok, req, {transport, {start_time, 0}}}
  end

  # handle is where we actually figure out how we're going to route the request
  def handle(req, {transport, {start_time, _end_time}}) do
    {path, req} = :cowboy_req.path(req)

    if path == "/openaperture_router_status_check" do
      # This request is meant for the router itself, so no need to route it
      # anywhere else.
      req = handle_status_request(req)
      {:ok, req, {transport, {start_time, 0}}}
    else
      {result, req, duration} = handle_request(req, path, transport)
      {result, req, {transport, {start_time, duration}}}
    end
  end

  # terminate is called by cowboy to allow us to clean up after the request has
  # completed.
  def terminate(_reason, _req, {_transport, {start_time, req_time}}) do
    total_time = :timer.now_diff(:os.timestamp(), start_time)

    total_time_ms = div(total_time, 1000)
    router_time_ms = div(total_time - req_time, 1000)

    Logger.info "Total request time (time in router): #{total_time_ms}ms (#{router_time_ms}ms)."
  end

  def terminate(reason, _req, _state) do
    Logger.error "Terminating request due to error: #{inspect reason}"
    :ok
  end

  ### Internal impl ###

  # Handler specifically for router health checks
  defp handle_status_request(req) do
    status = case OpenAperture.Router.RouteServer.get_last_fetch_timestamp do
      nil ->
        # Routes haven't been loaded yet, so we can't process requests...
        503
      last_fetch ->
        # Todo: make this TTL configurable
        ttl = 600 # in seconds

        now = :os.timestamp()
              |> erlang_timestamp_to_unix_timestamp

        if now - last_fetch > ttl do
          # If it's been more than `ttl` seconds since we've updated, the
          # router shouldn't be considered healthy
          Logger.error "Routes haven't been updated since #{inspect last_fetch}. Router is not healthy."
          503
        else
          # It's been less than `ttl` seconds since our last update, so the
          # router seems to be healthy.
          200
        end
    end

    Logger.debug "Handling status request. Replying with #{status}"
    {:ok, req} = :cowboy_req.reply(status, req)

    req
  end

  # Returns a tuple indicating success or failure, the newest copy of the
  # cowboy_req record, and an integer indicating how much time (in microsecs)
  # the backend server took to complete the request.
  defp handle_request(req, path, transport) do
    proto = case transport do
      :ssl -> :https
      _ -> :http
    end

    ReverseProxy.proxy_request(req, path, proto)
  end
end