defmodule OpenAperture.Router.ResponseHandler do
  @moduledoc """
  The Response Handler module should be run as a separate process, as it is
  responsible for processing asynchronous response messages from the hackney
  http client, and in turn, passes that message data back to the calling
  process.
  """
  require Logger

  @doc """
  Initialize the response handler. Because the init function starts a
  (potentially long-running) function, `init` should only be called as part
  of spawning a new process.
  """
  @spec init(pid) :: :ok
  def init(backend_request_pid) do
    message_loop(backend_request_pid)
  end

  defp message_loop(backend_request_pid, state \\ %{}) do
    receive do
      {:hackney_response, _client_ref, {:status, status_code, reason}} ->
        state = Map.merge(state, 
          %{
            status_code: status_code,
            status_reason: reason
          })
        
        message_loop(backend_request_pid, state)

      {:hackney_response, _client_ref, {:headers, headers}} ->
        response = {state[:status_code], state[:status_reason], headers}
        send(backend_request_pid, {:response_got_initial_response, self, response})

        message_loop(backend_request_pid, state)

      {:hackney_response, _clienf_ref, :done} ->
        send(backend_request_pid, {:got_response_done, self})
        :ok

      {:hackney_response, _clienf_ref, chunk} when is_binary(chunk) ->
        send(backend_request_pid, {:got_response_chunk, self, chunk})

        message_loop(backend_request_pid, state)

      {:hackney_response, _client_ref, {:error, err}} ->
        Logger.error "Hackney sent an error response: #{inspect err}"
        send(backend_request_pid, {:response_error, self, err})

      other ->
        Logger.error "ReponseHandler received an unexpected message: #{inspect other}"
        message_loop(backend_request_pid, state)
    end
  end
end