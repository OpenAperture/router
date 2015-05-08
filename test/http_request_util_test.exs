defmodule OpenAperture.Router.HttpRequestUtil.Test do
  use ExUnit.Case, async: false
  alias OpenAperture.Router.HttpRequestUtil

  setup do
    :meck.new :cowboy_req

    on_exit fn -> :meck.unload end
  end

  test "get request method -- delete" do
    :meck.expect(:cowboy_req, :method, 1, {"delete", :req2})
    assert HttpRequestUtil.get_request_method(:req1) == {:delete, :req2}
  end

  test "get request method -- get" do
    :meck.expect(:cowboy_req, :method, 1, {"get", :req2})
    assert HttpRequestUtil.get_request_method(:req1) == {:get, :req2}
  end

  test "get request method -- head" do
    :meck.expect(:cowboy_req, :method, 1, {"head", :req2})
    assert HttpRequestUtil.get_request_method(:req1) == {:head, :req2}
  end

  test "get request method -- options" do
    :meck.expect(:cowboy_req, :method, 1, {"options", :req2})
    assert HttpRequestUtil.get_request_method(:req1) == {:options, :req2}
  end

  test "get request method -- patch" do
    :meck.expect(:cowboy_req, :method, 1, {"patch", :req2})
    assert HttpRequestUtil.get_request_method(:req1) == {:patch, :req2}
  end

  test "get request method -- post" do
    :meck.expect(:cowboy_req, :method, 1, {"post", :req2})
    assert HttpRequestUtil.get_request_method(:req1) == {:post, :req2}
  end

  test "get request method -- put" do
    :meck.expect(:cowboy_req, :method, 1, {"put", :req2})
    assert HttpRequestUtil.get_request_method(:req1) == {:put, :req2}
  end

  test "get request method -- custom verb" do
    :meck.expect(:cowboy_req, :method, 1, {"coolverb", :req2})
    assert HttpRequestUtil.get_request_method(:req1) == {"coolverb", :req2}
  end

  test "get backend url -- no request port" do
    :meck.expect(:cowboy_req, :host_url, 1, {"https://testhost.somedomain.co", :req2})
    :meck.expect(:cowboy_req, :url, 1, {"https://testhost.somedomain.co", :req3})

    assert HttpRequestUtil.get_backend_url(:req1, "backend-host", 45900, false) == {"http://backend-host:45900", :req3}
  end

  test "get backend url -- with request port" do
    :meck.expect(:cowboy_req, :host_url, 1, {"https://testhost.somedomain.co:1234", :req2})
    :meck.expect(:cowboy_req, :url, 1, {"https://testhost.somedomain.co:1234", :req3})

    assert HttpRequestUtil.get_backend_url(:req1, "backend-host", 45900, false) == {"http://backend-host:45900", :req3}
  end

  test "get backend url -- with request path and querystring" do
    :meck.expect(:cowboy_req, :host_url, 1, {"https://testhost.somedomain.co", :req2})
    :meck.expect(:cowboy_req, :url, 1, {"https://testhost.somedomain.co/some/request/path?querystring=true", :req3})

    assert HttpRequestUtil.get_backend_url(:req1, "backend-host", 45900, false) == {"http://backend-host:45900/some/request/path?querystring=true", :req3}
  end

  test "get backend url -- request not https, backend with https" do
    :meck.expect(:cowboy_req, :host_url, 1, {"http://testhost.somedomain.co", :req2})
    :meck.expect(:cowboy_req, :url, 1, {"http://testhost.somedomain.co", :req3})

    assert HttpRequestUtil.get_backend_url(:req1, "backend-host", 45900, true) == {"https://backend-host:45900", :req3}
  end

  test "get backend url -- request with https, backend with https" do
    :meck.expect(:cowboy_req, :host_url, 1, {"https://testhost.somedomain.co", :req2})
    :meck.expect(:cowboy_req, :url, 1, {"https://testhost.somedomain.co", :req3})

    assert HttpRequestUtil.get_backend_url(:req1, "backend-host", 45900, true) == {"https://backend-host:45900", :req3}
  end

  test "chunked_request? with a transfer-encoding: chunked header returns true" do
    assert HttpRequestUtil.chunked_request?([{"transfer-encoding", "chunked"}]) == true
  end

  test "chunked_request? without a transfer-encoding: chunked header returns false" do
    assert HttpRequestUtil.chunked_request?([{"literally", "anything else"}]) == false
  end

  test "chunked_request? with a transfer-encoding: something-else header returns false" do
    assert HttpRequestUtil.chunked_request?([{"transfer-encoding", "something else"}]) == false
  end

  test "chunked_request? with a list of headers" do
    headers = [
      {"literally", "anything else"},
      {"not", "here either"},
      {"transfer-encoding", "chunked"},
      {"and", "one more"}]

    assert HttpRequestUtil.chunked_request?(headers) == true
  end

  test "get_content_length_or_transfer_encoding -- returns CL header if present" do
    assert HttpRequestUtil.get_content_length_or_transfer_encoding([{"content-length", "1234"}]) == {"content-length", "1234"}
  end

  test "get_content_length_or_transfer_encoding -- returns TE header if present" do
    assert HttpRequestUtil.get_content_length_or_transfer_encoding([{"transfer-encoding", "chunked"}]) == {"transfer-encoding", "chunked"}
  end

  test "get_content_length_or_transfer_encoding -- returns CL if both present" do
    assert HttpRequestUtil.get_content_length_or_transfer_encoding([{"content-length", "1234"}, {"transfer-encoding", "chunked"}]) == {"content-length", "1234"}
  end

  test "get_content_length_or_transfer_encoding -- returns nil if neither present" do
    assert HttpRequestUtil.get_content_length_or_transfer_encoding([{"literally", "anything else"}]) == nil
  end

  test "get_content_length_or_transfer_encoding -- preserves case" do
    assert HttpRequestUtil.get_content_length_or_transfer_encoding([{"Transfer-Encoding", "CHUNKED"}]) == {"Transfer-Encoding", "CHUNKED"}
  end

  test "get_content_length_header -- returns content-length if present" do
    assert HttpRequestUtil.get_content_length_header([{"content-length", "1234"}]) == {"content-length", "1234"}
  end

  test "get_content_length_header -- returns nil if headers list is empty" do
    assert HttpRequestUtil.get_content_length_header([]) == nil
  end

  test "get_content_length_header -- returns nil if there is no content-length header" do
    assert HttpRequestUtil.get_content_length_header([{"Transfer-Encoding", "chunked"}]) == nil
  end

  test "get_content_length_header -- preserves case" do
    assert HttpRequestUtil.get_content_length_header([{"Content-Length", "1234"}]) == {"Content-Length", "1234"}
  end
end