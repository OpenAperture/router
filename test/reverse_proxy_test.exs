defmodule OpenAperture.Router.ReverseProxy.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.ReverseProxy

  alias OpenAperture.Router.BackendRequestServer

  setup do
    :meck.new :cowboy_req

    on_exit fn ->
      :meck.unload
      ConCache.delete(:routes, "test.com:80")
    end
  end

  test "with no routes in cache, should return 503" do
    :meck.expect :cowboy_req, :host, 1, {"test.com", :req1}
    :meck.expect :cowboy_req, :port, 1, {80, :req2}

    :meck.expect :cowboy_req, :reply, fn status, :req2 ->
      assert status == 503
      {:ok, :req3}
    end

    result = proxy_request(:req, "/", :https)
      assert result == {:ok, :req3, 0}
  end

  test "should add router headers" do
    :meck.expect :cowboy_req, :host, 1, {"test.com", :req1}
    :meck.expect :cowboy_req, :port, 1, {80, :req2}
    :meck.expect :cowboy_req, :method, 1, {"GET", :req3}
    :meck.expect :cowboy_req, :headers, 1, {[{"accept", "application/json"}], :req4}
    :meck.expect :cowboy_req, :peer, 1, {{{127, 0, 0, 1}, 34567}, :req5}
    :meck.expect :cowboy_req, :host_url, 1, {"http://test.com", :req6}
    :meck.expect :cowboy_req, :url, 1, {"http://test.com", :req7}

    ConCache.put(:routes, "test.com:80", [{"east.test.com", 80, false},
                                          {"west.test.com", 80, false},
                                          {"north.test.com", 80, false},
                                          {"south.test.com", 80, false}])

    :meck.expect BackendRequestServer, :start_request, fn pid, _method, _url, headers, _has_body ->
      assert List.keyfind(headers, "X-Forwarded-Proto", 0) == {"X-Forwarded-Proto", "https"}
      assert List.keyfind(headers, "X-Forwarded-Port", 0) == {"X-Forwarded-Port", "80"}
      assert List.keyfind(headers, "X-Forwarded-Host", 0) == {"X-Forwarded-Host", "test.com"}
      assert List.keymember?(headers, "X-Forwarded-For", 0)
      assert List.keymember?(headers, "X-OpenAperture-Request-ID", 0)

      send(self, {:backend_request_initial_response, pid, 200, "OK", []})
      send(self, {:backend_request_done, pid, 0})

      {:ok, 0}
    end

    :meck.expect :cowboy_req, :reply, 4, {:ok, :req8}

    result = proxy_request(:req, "/", :https)

    assert result == {:ok, :req8, 0}
  end
end