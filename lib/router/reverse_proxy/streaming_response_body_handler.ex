defmodule OpenAperture.Router.ReverseProxy.StreamingResponseBodyHandler do
  @moduledoc """
  This module contains the handler for processing streaming response bodies.
  """

  # Read the timeouts info from the env config
  @timeouts Application.get_env(:openaperture_router, :timeouts, [
    connecting: 5_000,
    sending_request_body: 60_000,
    waiting_for_response: 60_000,
    receiving_response: 60_000
    ])

  #@doc handle_streaming_response_body()
  def handle(socket, transport) do
    timeout = Keyword.get(@timeouts, :receiving_response, 5_000)

    receive do
      {:backend_request_error, _backend_request_server_pid, _reason, backend_duration} ->
        # Todo: See if we can glean some information from the `reason` param
        # which might allow us to set a more helpful status code.
        {:error, backend_duration}

      {:backend_request_response_chunk, _backend_request_server_pid, chunk} ->
        transport.send(socket, chunk)

        # Recursively loop back into this handler until we're done.
        handle(socket, transport)

      {:backend_request_done, _backend_request_server_pid, _backend_duration} ->
        # Cowboy should close the connection for us, so all we should need to
        # do here is return, closing out the message loop.
        :ok

    after timeout -> :timeout
    end
  end
end