defmodule OpenAperture.Router.ReverseProxy.Client do
  @moduledoc """
  This module contains functions for handling Client <-> ReverseProxy
  functionality.
  """
  require Logger
  
  alias OpenAperture.Router.BackendRequestServer
  alias OpenAperture.Router.Types

  # Read the timeouts info from the env config
  @timeouts Application.get_env(:openaperture_router, :timeouts, [
    connecting: 5_000,
    sending_request_body: 60_000,
    waiting_for_response: 60_000,
    receiving_response: 60_000
    ])
  
  @doc """
  Sends the request body from the client to the backend server.
  """
  @spec send_request_body(Types.cowboy_req, pid, integer) :: {:ok, Types.cowboy_req, integer} | {:error, any, Types.cowboy_req, integer}
  def send_request_body(req, backend_request_server_pid, time \\ 0) do
    {req_time, result} = :timer.tc(:cowboy_req, :body, [req, [length: 4096, read_length: 4096]])
    case result do
       {:error, reason} ->
        Logger.error "Error retrieving request body: #{inspect reason}"
        {:error, reason, req, time}

      {:more, chunk, req} ->
        case BackendRequestServer.send_request_chunk(backend_request_server_pid, chunk, false) do
          {:ok, send_chunk_time} ->
            send_request_body(req, backend_request_server_pid, time + req_time + send_chunk_time)
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

  @doc """
  Sends a response body chunk from the backend down to the client.
  """
  @spec send_response_body_chunk(Types.cowboy_req, String.t) :: {:ok, integer} | {:error, integer}
  def send_response_body_chunk(req, chunk) do
    {time, result} = :timer.tc(:cowboy_req, :chunk, [chunk, req])
    case result do
      :ok -> {:ok, time}
      {:error, reason} ->
        Logger.error "Error sending chunk to client: #{inspect reason}"
        {:error, time}
    end
  end

  @doc """
  Sends a complete response, including the response body. This should be used
  when the response body is small. For large (but non-chunked) response bodies,
  use `start_streaming_reply/3`.
  """
  @spec send_reply(Types.cowboy_req, String.t, Types.headers, String.t) :: {Types.cowboy_req, Types.microseconds}
  def send_reply(req, status, headers, body) do
    {reply_time, {:ok, req}} = :timer.tc(:cowboy_req, :reply, [status, headers, body, req])

    {req, reply_time}
  end

  @doc """
  Sends a response without a response body. This is usually used when the
  response body should be streamed.
  """
  @spec send_reply(Types.cowboy_req, String.t, Types.headers) :: {Types.cowboy_req, Types.microseconds}
  def send_reply(req, status, headers) do
    {reply_time, {:ok, req}} = :timer.tc(:cowboy_req, :reply, [status, headers, req])
    {req, reply_time}
  end

  @doc """
  Initiates a chunked reply. This will send the status line and response
  headers to the client, but the does not indicate the request is "completed",
  as the response body chunks will be sent afterwards.
  """
  @spec start_chunked_reply(Types.cowboy_req, String.t, Types.headers) :: {Types.cowboy_req, Types.microseconds}
  def start_chunked_reply(req, status_line, headers) do
    {reply_time, {:ok, req}} = :timer.tc(:cowboy_req, :chunked_reply, [status_line, headers, req])

    {req, reply_time}
  end

  @doc """
  Adds OpenAperture Router-specific request headers, which can be used by the
  backend servers to get information regarding the original request. Because 
  the router proxies the request, many of the normal versions of these headers
  will be set with router-specific information, which might not be especially
  useful for the backend server. The added headers are:
    * X-OpenAperture-Request-ID - A unique identifier for the request.
    * X-Forwarded-For - The address of the remote client (ip:port, usually).
    * X-Forwarded-Host - The original hostname used for the request.
    * X-Forwarded-Port - The original port used for the request.
    * X-Forwarded-Proto - The original protocol (http or https) used for the
                          request.
  """
  @spec add_router_request_headers(Types.headers, String.t, integer, Types.cowboy_req, :http | :https) :: {Types.headers, Types.cowboy_req}
  def add_router_request_headers(headers, host, port, req, proto) when is_list(headers) do
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

  @spec add_request_id_header(Types.headers) :: Types.headers
  defp add_request_id_header(headers) do
    request_id = UUID.uuid4(:hex)
    [{"X-OpenAperture-Request-ID", request_id}] ++ headers
  end

  @spec add_forwarded_for_header(Types.headers, Types.cowboy_req) :: {Types.headers, Types.cowboy_req}
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

  @spec add_forwarded_host_header(Types.headers, String.t) :: Types.headers
  defp add_forwarded_host_header(headers, host) do
    [{"X-Forwarded-Host", host}] ++ headers
  end

  @spec add_forwarded_port_header(Types.headers, integer) :: Types.headers
  defp add_forwarded_port_header(headers, port) do
    [{"X-Forwarded-Port", Integer.to_string(port)}] ++ headers
  end

  @spec add_forwarded_proto_header(Types.headers, atom) :: Types.headers
  defp add_forwarded_proto_header(headers, proto) do
    [{"X-Forwarded-Proto", Atom.to_string(proto)}] ++ headers
  end
end