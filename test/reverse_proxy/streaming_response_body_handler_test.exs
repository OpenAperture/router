defmodule OpenAperture.Router.ReverseProxy.StreamingResponseBodyHandler.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.ReverseProxy.StreamingResponseBodyHandler

  setup do
    :meck.new :ranch_tcp
  end

  test "sends data over the socket" do
    :meck.expect :ranch_tcp, :send, [{[:socket, "HELLO"], :ok},
                                     {[:socket, "WORLD"], :ok}]

    send(self, {:backend_request_response_chunk, :pid, "HELLO"})
    send(self, {:backend_request_response_chunk, :pid, "WORLD"})
    send(self, {:backend_request_done, :pid, 100})

    result = handle(:socket, :ranch_tcp)

    assert result == :ok
  end
end