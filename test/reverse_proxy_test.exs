defmodule OpenAperture.Router.ReverseProxy.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.ReverseProxy

  alias OpenAperture.Router.HttpRequestUtil
  alias OpenAperture.Router.ReverseProxy
  alias OpenAperture.Router.ReverseProxy.Backend
  alias OpenAperture.Router.ReverseProxy.BufferedResponseBodyHandler
  alias OpenAperture.Router.ReverseProxy.ChunkedResponseBodyHandler
  alias OpenAperture.Router.ReverseProxy.Client
  alias OpenAperture.Router.RouteCache

  setup do
    :meck.new :cowboy_req
    :meck.new Backend
    :meck.new BufferedResponseBodyHandler
    :meck.new ChunkedResponseBodyHandler
    :meck.new Client, [:passthrough]
    :meck.new HttpRequestUtil, [:passthrough]
    :meck.new ReverseProxy, [:passthrough]
    :meck.new RouteCache

    on_exit fn ->
      :meck.unload
      ConCache.delete(:routes, "test.com:80")
    end
  end

  test "with no routes in cache, should return 503" do
    :meck.expect :cowboy_req, :host, 1, {"test.com", :req1}
    :meck.expect :cowboy_req, :port, 1, {80, :req2}
    :meck.expect RouteCache, :get_route_for_authority, [{["test.com", 80, :_], nil}]
    :meck.expect Client, :send_reply, [{[:req2, "503 Service Unavailable", [], ""], {:req3, 0}}]

    result = proxy_request(:req, "/", :https)
      assert result == {:ok, :req3, 0}
  end

  # Need to move message loop functionality in reverse_proxy/backend
  # and reverse_proxy/client
  test "should add router headers" do
    :meck.expect(:cowboy_req, :host, 1, {"test", :req1})
    :meck.expect(:cowboy_req, :port, 1, {80, :req2})

    :meck.expect(RouteCache, :get_route_for_authority, 3, {"east.test", 80, false})

    :meck.expect HttpRequestUtil, :get_request_method, 1, {:get, :req3}
    :meck.expect :cowboy_req, :headers, 1, {[{"accept", "application/json"}], :req4}
    :meck.expect :cowboy_req, :peer, 1, {{{127, 0, 0, 1}, 34567}, :req5}
    :meck.expect :cowboy_req, :host_url, 1, {"http://test", :req6}
    :meck.expect :cowboy_req, :url, 1, {"http://test", :req7}

    :meck.expect(Backend, :start_request, fn (_method, __url, headers, _has_body) ->
      assert List.keyfind(headers, "X-Forwarded-Proto", 0) == {"X-Forwarded-Proto", "https"}
      assert List.keyfind(headers, "X-Forwarded-Port", 0) == {"X-Forwarded-Port", "80"}
      assert List.keyfind(headers, "X-Forwarded-Host", 0) == {"X-Forwarded-Host", "test"}
      assert List.keymember?(headers, "X-Forwarded-For", 0)
      assert List.keymember?(headers, "X-OpenAperture-Request-ID", 0)

      {:ok, :pid, 1}
    end)

    :meck.expect :cowboy_req, :set_meta, [{[:response_type, :streaming, :req7], :req8}]
    :meck.expect Client, :send_reply, [{[:req8, "200 OK", :_], {:req9, 100}}]

    send(self, {:backend_request_initial_response, :pid, 200, "OK", [{"content-type", "text/plain"}], 100})
    send(self, {:backend_request_done, :pid, 100})

    result = proxy_request(:req, "/", :https)

    assert result == {:ok, :req9, 200}
  end

  test "should use the ChunkedResponseBodyHandler for chunked responses" do
    method = :get
    host = "test"
    port = 80
    is_https = false
    headers = [{"content-type", "text/plain"}]
    response_headers = [{"transfer-encoding", "chunked"}]
    url = "http://test"
    :meck.expect HttpRequestUtil, :get_backend_url, [{[:req1, host, port, is_https], {url, :req2}}]
    :meck.expect Backend, :start_request, [{[method, url, headers, false], {:ok, :pid, 1}}]
    :meck.expect :cowboy_req, :set_meta, [{[:response_type, :chunked, :req2], :req3}]
    :meck.expect Client, :start_chunked_reply, [{[:req3, "200 OK", response_headers], {:req4, 1}}]
    :meck.expect ChunkedResponseBodyHandler, :handle, [{[:req4, :pid], {:ok, :req5, 100}}]

    send(self, {:backend_request_initial_response, :pid, 200, "OK", response_headers, 100})

    result = proxy_request(method, :req1, host, port, is_https, headers)

    assert result == {:ok, :req5, 100}
  end

  test "should use BufferedResponseBodyHandler for a buffered response" do
    method = :get
    host = "test"
    port = 80
    is_https = false
    headers = [{"content-type", "text/plain"}]
    response_headers = [{"content-length", "11"}]
    url = "http://test"

    :meck.expect HttpRequestUtil, :get_backend_url, [{[:req1, host, port, is_https], {url, :req2}}]
    :meck.expect Backend, :start_request, [{[method, url, headers, false], {:ok, :pid, 1}}]
    :meck.expect :cowboy_req, :set_meta, [{[:response_type, :buffered, :req2], :req3}]
    :meck.expect BufferedResponseBodyHandler, :handle, [{[:req3, :pid, "200 OK", response_headers], {:ok, :req4, 100}}]

    send(self, {:backend_request_initial_response, :pid, 200, "OK", response_headers, 100})

    result = proxy_request(method, :req1, host, port, is_https, headers)

    assert result == {:ok, :req4, 100}
  end

  test "should send a reply and set response_type to streaming for a large response" do
    method = :get
    host = "test"
    port = 80
    is_https = false
    headers = [{"content-type", "text/plain"}]
    response_headers = [{"content-length", "100000000000"}]
    url = "http://test"

    :meck.expect HttpRequestUtil, :get_backend_url, [{[:req1, host, port, is_https], {url, :req2}}]
    :meck.expect Backend, :start_request, [{[method, url, headers, false], {:ok, :pid, 1}}]
    :meck.expect :cowboy_req, :set_meta, [{[:response_type, :streaming, :req2], :req3}]
    :meck.expect Client, :send_reply, [{[:req3, "200 OK", response_headers], {:req4, 100}}]

    send(self, {:backend_request_initial_response, :pid, 200, "OK", response_headers, 100})

    result = proxy_request(method, :req1, host, port, is_https, headers)

    assert result == {:ok, :req4, 200}
  end

  test "should send a reply and set response_type to streaming for a response with no transfer-encoding=chunked header and no content-length header" do
    method = :get
    host = "test"
    port = 80
    is_https = false
    headers = [{"content-type", "text/plain"}]
    response_headers = [{"content-type", "text/plain"}]
    url = "http://test"

    :meck.expect HttpRequestUtil, :get_backend_url, [{[:req1, host, port, is_https], {url, :req2}}]
    :meck.expect Backend, :start_request, [{[method, url, headers, false], {:ok, :pid, 1}}]
    :meck.expect :cowboy_req, :set_meta, [{[:response_type, :streaming, :req2], :req3}]
    :meck.expect Client, :send_reply, [{[:req3, "200 OK", response_headers], {:req4, 100}}]

    send(self, {:backend_request_initial_response, :pid, 200, "OK", response_headers, 100})

    result = proxy_request(method, :req1, host, port, is_https, headers)

    assert result == {:ok, :req4, 200}
  end
end