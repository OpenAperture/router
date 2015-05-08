defmodule OpenAperture.Router.ReverseProxy.Backend do
  @moduledoc """
  This module contains functions for handling
  BackendRequestServer <-> ReverseProxy functionality.
  """

  require Logger

  alias OpenAperture.Router.BackendRequestServer
  alias OpenAperture.Router.Types

  @doc """
  Creates a backend request server genserver process and initiates the request.
  """
  @spec start_request(atom, String.t, Types.headers, boolean) :: {:ok, pid, Types.microseconds} | {:error, Types.microseconds}
  def start_request(method, url, headers, has_body) do
    # Start performing the backend request in a separate process
    {:ok, backend_request_server_pid} = GenServer.start(BackendRequestServer, self)

    result = BackendRequestServer.start_request(backend_request_server_pid, method, url, headers, has_body)
    case result do
      {:error, reason, request_time} ->
        Logger.error "An error occurred initiating the request to #{url}: #{inspect reason}"
        {:error, reason, request_time}
      {:ok, request_time} ->
        {:ok, backend_request_server_pid, request_time}
    end
  end
end