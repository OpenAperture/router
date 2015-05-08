defmodule OpenAperture.Router.ReverseProxy.ChunkedResponseBodyHandler do
  @moduledoc """
  This module contains the handler for processing chunked response bodies.
  """

  alias OpenAperture.Router.ReverseProxy.Client
  alias OpenAperture.Router.Types

  # Read the timeouts info from the env config
  @timeouts Application.get_env(:openaperture_router, :timeouts, [
    connecting: 5_000,
    sending_request_body: 60_000,
    waiting_for_response: 60_000,
    receiving_response: 60_000
    ])

  @doc """
  Handles chunks coming from the backend server and forwards them on to the
  client. This function will recurse into itself until it receives the
  :backend_request_done message, at which point it will return.
  """
  @spec handle(Types.cowboy_req, pid) ::  {:ok | :error, Types.cowboy_req, Types.microseconds} | {:error, :timeout}
  def handle(req, backend_request_server_pid) do
    timeout = Keyword.get(@timeouts, :receiving_response, 5_000)
    receive do
      {:backend_request_error, ^backend_request_server_pid, _reason, backend_duration} ->
        # Todo: See if we can glean some information from the `reason` param
        # which might allow us to set a more helpful status code.
        {:error, req, backend_duration}

      {:backend_request_response_chunk, ^backend_request_server_pid, chunk} ->
        {_result, _send_time} = Client.send_response_body_chunk(req, chunk)

        # Recursively loop back into this handler until we're done.
        handle(req, backend_request_server_pid)

      {:backend_request_done, ^backend_request_server_pid, backend_duration} ->
        # Cowboy should close the connection for us, so all we should need to
        # do here is return, closing out the message loop.
        {:ok, req, backend_duration}

    after timeout ->
      {:error, :timeout}
    end
  end
end