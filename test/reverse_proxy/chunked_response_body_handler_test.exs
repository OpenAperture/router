defmodule OpenAperture.Router.ReverseProxy.ChunkedResponseBodyHandler.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.ReverseProxy.ChunkedResponseBodyHandler

  alias OpenAperture.Router.ReverseProxy.Client

  setup do
    :meck.new Client

    on_exit fn -> :meck.unload end
  end

  test "returns error on an error message" do
    send(self, {:backend_request_error, :pid, "oh no!", 100})

    result = handle(:req, :pid)

    assert result == {:error, :req, 100}
  end

  test "sends chunks to the client" do
    send(self, {:backend_request_response_chunk, :pid, "HELLO"})
    send(self, {:backend_request_response_chunk, :pid, "WORLD"})
    send(self, {:backend_request_done, :pid, 100})

    :meck.expect Client, :send_response_body_chunk, [{[:req, "HELLO"], {:ok, 1}},
                                                     {[:req, "WORLD"], {:ok, 1}}]

    result = handle(:req, :pid)

    assert result == {:ok, :req, 100}
  end

  test "should return an error if an error occurrs sending chunks" do
    send(self, {:backend_request_response_chunk, :pid, "bummer"})

    :meck.expect Client, :send_response_body_chunk, [{[:req, "bummer"], {:error, 1}}]

    result = handle(:req, :pid)

    assert result == {:error, :req, 0}
  end
end