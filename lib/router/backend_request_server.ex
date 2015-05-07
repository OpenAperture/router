defmodule OpenAperture.Router.BackendRequestServer do
  @moduledoc """
  The BackendRequest GenServer handles issuing the proxied request to the
  backend server, streaming the request body from the client to the backend
  server, and streaming the response from the server back to the client.
  """
  require Logger
  use GenServer

  import OpenAperture.Router.Util

  alias OpenAperture.Router.Types

  ## Client API
  @doc """
  Initiates the request to the backend. Requires the request method, the
  backend url, the set of request headers, and a boolean flag indicating that
  it should prepare to stream a request body.

  Returns {:ok, duration} on success, or {:error, reason, duration} on failure.
  """
  @spec start_request(pid, atom, String.t, Types.headers, boolean) :: {:ok, Types.microseconds} | {:error, any, Types.microseconds}
  def start_request(pid, method, url, request_headers, has_request_body) do
    GenServer.call(pid, {:start_request, method, url, request_headers, has_request_body})
  end

  @doc """
  Send a chunk of the request body to the backend server. The `is_last_chunk`
  flag is used to indicate that there are no more body chunks to be sent.

  Returns {:ok, duration} on success, or {:error, reason, duration} on failure.
  """
  @spec send_request_chunk(pid, String.t, boolean) :: {:ok, Types.microseconds} | {:error, any, Types.microseconds}
  def send_request_chunk(pid, chunk, is_last_chunk) do
    GenServer.call(pid, {:send_request_chunk, chunk, is_last_chunk})
  end

  ## Server API
  @doc """
  Initialize the BackendRequestServer. Requires the pid of the calling process,
  to which it will send messages containing the responses from the backend
  server.
  """
  def init(parent_pid) do
    {:ok, %{parent_pid: parent_pid}}
  end

  # Returns
  # {:ok, duration}
  # {:error, reason, duration}
  def handle_call({:start_request, method, url, request_headers, has_request_body}, _from, state) do
    hackney_options = [:async, {:stream_to, self}]
    hackney_options = get_hackney_options(url) ++ hackney_options

    if has_request_body do
      {time, result} = :timer.tc(:hackney, :request, [method, url, request_headers, :stream, hackney_options])
    else
      {time, result} = :timer.tc(:hackney, :request, [method, url, request_headers, "", hackney_options])
    end

    state = Map.put(state, :request_start, :os.timestamp)

    case result do
      {:ok, client} ->
        Logger.debug "Client #{inspect client} successfully initiated request."
        {:reply, {:ok, time}, Map.put(state, :hackney_client, client)}
      {:error, reason} ->
        {:stop, :normal, {:error, reason, time}, state}
    end
  end

  # Returns
  # {:ok, duration}
  # {:error, reason, duration}
  def handle_call({:send_request_chunk, chunk, false}, _from, %{hackney_client: client} = state) do
    {time, result} = :timer.tc(:hackney, :send_body, [client, chunk])
    case result do
      :ok -> {:reply, {:ok, time}, state}
      {:error, reason} -> {:reply, {:error, reason, time}, state}
    end
  end

  # Returns
  # {:ok, duration}
  # {:error, reason, duration}
  def handle_call({:send_request_chunk, chunk, true}, _from, %{hackney_client: client} = state) do
    {time, result} = :timer.tc(:hackney, :send_body, [client, chunk])
    case result do
      :ok ->
        {response_time, result} = :timer.tc(:hackney, :start_response, [client])
        case result do
          {:ok, client} -> {:reply, {:ok, time + response_time}, %{state | hackney_client: client}}
          {:error, reason} -> {:reply, {:error, reason, time + response_time}, state}
        end
      {:error, reason} -> {:reply, {:error, reason, time}, state}
    end
  end

  ### Handlers for Hackney messages
  def handle_info({:hackney_response, client_ref, {:status, status_code, reason}}, state) do
    Logger.debug("Client #{inspect client_ref} received response with status #{status_code} (#{reason})")
    state = Map.merge(state, %{response: %{status_code: status_code, reason: reason}})
    {:noreply, state}
  end

  def handle_info({:hackney_response, client_ref, {:headers, headers}}, %{parent_pid: parent} = state) do
    Logger.debug("Client #{inspect client_ref} received response headers: #{inspect headers}")
    # Send info to the parent reverse proxy process with the initial response data
    response = state[:response]
    send(parent, {:backend_request_initial_response, self, response[:status_code], response[:reason], headers})
    # We don't need that response map anymore, so ditch it
    {:noreply, Map.delete(state, :response)}
  end

  def handle_info({:hackney_response, client_ref, :done}, %{parent_pid: parent} = state) do
    now = :os.timestamp
    Logger.debug("Client #{inspect client_ref} received hackney message indicating the request has completed. Shutting down BackendRequestServer GenServer...")
    duration = :timer.now_diff(now, state[:request_start])
    send(parent, {:backend_request_done, self, duration})
    {:stop, :normal, state}
  end

  def handle_info({:hackney_response, client_ref, {:error, error}}, %{parent_pid: parent} = state) do
    Logger.error("Client #{inspect client_ref} received hackney error: #{inspect error}")
    send(parent, {:backend_request_error, self, error})
    {:noreply, state}
  end

  def handle_info({:hackney_response, _client_ref, chunk}, %{parent_pid: parent} = state) do
    send(parent, {:backend_request_response_chunk, self, chunk})
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug "Response Handler server received an unexpected message: #{inspect msg}"
    {:noreply, state}
  end
end