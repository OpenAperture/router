defmodule OpenAperture.Router.ReverseProxy.Client.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.ReverseProxy.Client

  alias OpenAperture.Router.BackendRequestServer

  setup do
    :meck.new :cowboy_req
    :meck.new BackendRequestServer
    :meck.new UUID, [:passthrough]

    on_exit fn -> :meck.unload end
  end

  test "send_request_body - Returns an error if cowboy reports and error retrieving a body chunk" do
    :meck.expect(:cowboy_req, :body, 2, {:error, "oh no!"})

     
    {result, reason, req, time} = send_request_body(:req, :pid)

    assert result == :error
    assert reason == "oh no!"
    assert req == :req
    assert time >= 0
  end

  test "send_request_body - sends a chunk to the backend request server and returns on a single chunk request body" do
    :meck.expect(:cowboy_req, :body, 2, {:ok, "a chunk", :req1})
    :meck.expect(BackendRequestServer, :send_request_chunk, [{[:some_pid, "a chunk", true], {:ok, 100}}])

    {result, req, time} = send_request_body(:req, :some_pid)

    assert result == :ok
    assert req == :req1
    assert time >= 100
  end

  test "send_request_body - returns error if an error occurred sending a chunk to the backend request server on a single chunk request body" do
    :meck.expect(:cowboy_req, :body, 2, {:ok, "a chunk", :req1})
    :meck.expect(BackendRequestServer, :send_request_chunk, [{[:some_pid, "a chunk", true], {:error, "oh no!", 100}}])

    {result, reason, req, time} = send_request_body(:req, :some_pid)

     assert result == :error
     assert reason == "oh no!"
     assert req == :req1
     assert time >= 100
  end

  test "send_request_body - sends multiple chunks to the backend request server and returns on a multiple chunk request body" do
    :meck.expect(:cowboy_req, :body, [{[:req, :_], {:more, "first chunk", :req1}},
                                      {[:req1, :_], {:more, "second chunk", :req2}},
                                      {[:req2, :_], {:ok, "last chunk", :req3}}])
    :meck.expect(BackendRequestServer, :send_request_chunk, [{[:some_pid, "first chunk", false], {:ok, 100}},
                                                             {[:some_pid, "second chunk", false], {:ok, 100}},
                                                             {[:some_pid, "last chunk", true], {:ok, 100}}])

    {result, req, time} = send_request_body(:req, :some_pid)

    assert result == :ok
    assert req == :req3
    assert time >= 300
  end

  test "send_request_body - returns error if an error occurred sending the first chunk to the backend request server on a multiple chunk request body" do
    :meck.expect(:cowboy_req, :body, 2, {:more, "a chunk", :req1})
    :meck.expect(BackendRequestServer, :send_request_chunk, [{[:some_pid, "a chunk", false], {:error, "oh no!", 100}}])

    {result, reason, req, time} = send_request_body(:req, :some_pid)

     assert result == :error
     assert reason == "oh no!"
     assert req == :req1
     assert time >= 100
  end

  test "send_request_body - returns error if an error occurred sending the second chunk to the backend request server on a multiple chunk request body" do
    :meck.expect(:cowboy_req, :body, [{[:req, :_], {:more, "first chunk", :req1}},
                                      {[:req1, :_], {:more, "second chunk", :req2}}])
    :meck.expect(BackendRequestServer, :send_request_chunk, [{[:some_pid, "first chunk", false], {:ok, 100}},
                                                             {[:some_pid, "second chunk", false], {:error, "oh no!", 100}}])

    {result, reason, req, time} = send_request_body(:req, :some_pid)

     assert result == :error
     assert reason == "oh no!"
     assert req == :req2
     assert time >= 200
  end

  test "send_request_body - returns error if an error occurred sending the last chunk to the backend request server on a multiple chunk request body" do
    :meck.expect(:cowboy_req, :body, [{[:req, :_], {:more, "first chunk", :req1}},
                                      {[:req1, :_], {:more, "second chunk", :req2}},
                                      {[:req2, :_], {:ok, "last chunk", :req3}}])
    :meck.expect(BackendRequestServer, :send_request_chunk, [{[:some_pid, "first chunk", false], {:ok, 100}},
                                                             {[:some_pid, "second chunk", false], {:ok, 100}},
                                                             {[:some_pid, "last chunk", true], {:error, "oh no!", 100}}])

    {result, reason, req, time} = send_request_body(:req, :some_pid)

     assert result == :error
     assert reason == "oh no!"
     assert req == :req3
     assert time >= 300
  end

  test "send_response_body_chunk - returns :ok if response chunk is successfully sent" do
    :meck.expect(:cowboy_req, :chunk, [{["a chunk", :req], :ok}])

    {result, time} = send_response_body_chunk(:req, "a chunk")

    assert result == :ok
    assert time >= 0
  end

  test "send_response_body_chunk - returns error if an error occurs sending the resopnse body chunk" do
    :meck.expect(:cowboy_req, :chunk, [{["a chunk", :req], {:error, "oh no!"}}])

    {result, time} = send_response_body_chunk(:req, "a chunk")

    assert result == :error
    assert time >= 0
  end

  test "send_reply -- success" do
    status = "200 OK"
    headers = [{"Content-Type", "text/plain"}, {"Content-Length", "11"}]
    body = "HELLO WORLD"

    :meck.expect(:cowboy_req, :reply, [{[status, headers, body, :req], {:ok, :req1}}])

    {req, time} = send_reply(:req, status, headers, body)

    assert req == :req1
    assert time >= 0
  end

  test "start_chunked_reply -- success" do
    status = "200 OK"
    headers = [{"Content-Type", "text/plain"}, {"Transfer-Encoding", "chunked"}]

    :meck.expect(:cowboy_req, :chunked_reply, [{[status, headers, :req], {:ok, :req1}}])

    {req, time} = start_chunked_reply(:req, status, headers)

    assert req == :req1
    assert time >= 0
  end

  test "add_router_request_headers - Adds X-OpenAperture-Request-ID header" do
    :meck.expect :cowboy_req, :peer, [{[:req], {{{127, 0, 0, 1}, 34567}, :req1}}]
    :meck.expect UUID, :uuid4, [{[:hex], "0xDEADBEEF"}]

    {headers, req} = add_router_request_headers([], "test", 80, :req, :https)

    assert {"X-OpenAperture-Request-ID", "0xDEADBEEF"} in headers
    assert req == :req1
  end

  test "add_router_request_headers - Adds X-Forwarded-For header" do
    :meck.expect :cowboy_req, :peer, [{[:req], {{{127, 0, 0, 1}, 34567}, :req1}}]

    {headers, req} = add_router_request_headers([], "test", 80, :req, :https)

    assert {"X-Forwarded-For", "127.0.0.1:34567"} in headers
    assert req == :req1
  end

  test "add_router_request_headers - Adds X-Forwarded-For with value 'unknown' if peer can't be resolved correctly" do
    :meck.expect :cowboy_req, :peer, [{[:req], {{{:weird}, :invalid}, :req1}}]

    {headers, req} = add_router_request_headers([], "test", 80, :req, :https)

    assert {"X-Forwarded-For", "unknown"} in headers
    assert req == :req1
  end

  test "add_router_request_headers - Adds X-Forwarded-Host header" do
    :meck.expect :cowboy_req, :peer, [{[:req], {{{127, 0, 0, 1}, 34567}, :req1}}]

    {headers, req} = add_router_request_headers([], "test", 80, :req, :https)

    assert {"X-Forwarded-Host", "test"} in headers
    assert req == :req1
  end

  test "add_router_request_headers - Adds X-Forwarded-Port header" do
    :meck.expect :cowboy_req, :peer, [{[:req], {{{127, 0, 0, 1}, 34567}, :req1}}]

    {headers, req} = add_router_request_headers([], "test", 80, :req, :https)

    assert {"X-Forwarded-Port", "80"} in headers
    assert req == :req1
  end

  test "add_router_request_headers - Adds X-Forwarded-Proto header" do
    :meck.expect :cowboy_req, :peer, [{[:req], {{{127, 0, 0, 1}, 34567}, :req1}}]

    {headers, req} = add_router_request_headers([], "test", 80, :req, :https)

    assert {"X-Forwarded-Proto", "https"} in headers
    assert req == :req1
  end
end