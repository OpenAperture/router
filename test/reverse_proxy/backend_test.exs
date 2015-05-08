defmodule OpenAperture.Router.ReverseProxy.Backend.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.ReverseProxy.Backend

  alias OpenAperture.Router.BackendRequestServer

  setup do
    :meck.new BackendRequestServer, [:passthrough]

    on_exit fn -> :meck.unload end
  end

  test "start_request -- success" do
    :meck.expect BackendRequestServer, :start_request, 5, {:ok, 100}

    {result, pid, time} = start_request(:get, "http://test", [{"Content-Type", "text/plain"}], false)

    assert result == :ok
    assert Process.alive?(pid)
    assert time >= 100
  end

  test "start request -- error" do
    method = :get
    url = "http://test"
    headers = [{"Content-Type", "text/plain"}]
    has_body = false

    :meck.expect BackendRequestServer, :start_request, [{[:_, method, url, headers, has_body], {:error, "oh no!", 100}}]

    {result, reason, time} = start_request(method, url, headers, has_body)

    assert result == :error
    assert reason == "oh no!"
    assert time >= 100
  end
end