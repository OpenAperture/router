defmodule OpenAperture.Router.ReverseProxy.BufferedResponseBodyHandler.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.ReverseProxy.BufferedResponseBodyHandler

  alias OpenAperture.Router.ReverseProxy.Client

  setup do
    :meck.new Client

    on_exit fn -> :meck.unload end
  end

  test "returns error on an error message" do
    send(self, {:backend_request_error, :pid, "bummer", 100})

    result = handle(:req, :pid, "200 OK", [])

    assert result == {:error, :req, 100}
  end

  test "buffers all chunks, then replies" do
    :meck.expect Client, :send_reply, [{[:req, "200 OK", [], "HELLO WORLD"], {:req1, 100}}]
    send(self, {:backend_request_response_chunk, :pid, "HELLO "})
    send(self, {:backend_request_response_chunk, :pid, "WORLD"})
    send(self, {:backend_request_done, :pid, 100})

    result = handle(:req, :pid, "200 OK", [])

    assert result == {:ok, :req1, 200}
  end
end