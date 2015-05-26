defmodule OpenAperture.Router.RequestIntegrationTest do
  use ExUnit.Case

  # These tests use an [HTTParrot](http://github.com/edgurgel/httparrot)
  # instance as a backend server, and ensure that requests made to the router
  # are sent essentially unchanged to the backend server. HTTParrot responses
  # contain data indicating what the request the backend server received looked
  # like, so we can compare
  # original request -> router -> backend server
  # to
  # backend server response -> router -> response to see if the router is
  # sending the original requests correctly.

  @one_k_binary """
  INTRODUCTION


  The mechanical properties of wood are fitness and ability to resist applied or external forces. By external force is meant any force outside of a given piece of material which tends to deform it in any manner. It is largely such properties that determine the use of wood for structural and building purposes and innumerable other uses of which furniture, vehicles, implements, and tool handles are a few common examples.

  Knowledge of these properties is obtained through experimentation either in the employment of the wood in practice or by means of special testing apparatus in the laboratory. Owing to the wide range of variation in wood it is necessary that a great number of tests be made and that so far as possible all disturbing factors be eliminated. For comparison of different kinds or sizes a standard method of testing is necessary and the values must be expressed in some defined units. For these reasons laboratory experiments if properly conducted have many advantages over any other method.
  """

  setup do
    # Add a small sleep so the test doesn't shut down before the router
    # gets a chance to handle the `terminate` callback from cowboy.
    on_exit fn -> :timer.sleep(100) end
  end

  setup_all do
    # Add a host:port->route_host:port mapping for our httparrot server
    ConCache.put(:routes, "localhost:8080", [{"localhost", 4007, false}])
    :ok
  end

  defp request(method, url, headers \\ [], body \\ "") do
    case :hackney.request(method, url, headers, body, []) do
      {:ok, status_code, headers, _client} when status_code in [204, 304] ->
        {:ok, %{status_code: status_code, headers: headers, body: ""}}
      {:ok, status_code, headers} ->
        {:ok, %{status_code: status_code, headers: headers, body: ""}}
      {:ok, status_code, headers, client} ->
        response = %{status_code: status_code, headers: headers}
        case :hackney.body(client) do
          {:ok, body} -> {:ok, Map.put(response, :body, body)}
          {:error, reason} -> {:error, reason, response}
        end
      {:error, reason} -> {:error, reason}
      other -> {:error, "Unexpected response from hackney: #{inspect other}"}
    end
  end

  defp request_streaming_response(method, url, headers \\ [], body \\ "") do
    {:ok, _client} = :hackney.request(
      method,
      url,
      headers,
      body,
      [:async])

    response = handle_streaming_response()
    response
  end

  defp handle_streaming_response(response_map \\ %{status_code: nil, headers: [], chunks: []}) do
    receive do
      {:hackney_response, _client, {:status, status_code, _reason}} ->
        handle_streaming_response(Map.put(response_map, :status_code, status_code))
      {:hackney_response, _client, {:headers, headers}} ->
        handle_streaming_response(Map.put(response_map, :headers, headers))
      {:hackney_response, _client, :done} ->
        {:ok, response_map}
      {:hackney_response, _client, {:error, reason}} ->
        {:error, reason, response_map}
      {:hackney_response, _client, chunk} ->
        handle_streaming_response(Map.put(response_map, :chunks, response_map.chunks ++ [chunk]))
    end
  end

  # builds a tempfile
  defp build_tempfile(prefix, contents) do
    tmp_dir = System.tmp_dir!
    {mega, secs, _} = :erlang.now()
    unixtime = mega * 1_000_000 + secs

    filename = prefix <> "-#{unixtime}"

    path = Path.join(tmp_dir, filename)

    file = File.stream!(path)
    _result = File.write(file.path, contents)

    {:ok, file.path}
  end

  # HTTParrot's /get endpoint returns a json object that looks like:
  # %{
  #    "args" => %{}, # map of query string params
  #    "headers" => %{}, # map of request headers
  #    "origin" => 127.0.0.1, # ip address of requester
  #    "url" => "http://url" # full request url
  # }
  # Note that some of these values will reflect what HTTParrot sees coming
  # from the router, not what is necessarily sent to the router from the client
  test "GET test" do
    {:ok, response} = request(:get, "http://localhost:8080/get?a=a_value&b=b_value")
    body = Poison.decode!(response.body)
    assert %{"a" => "a_value", "b" => "b_value"} == body["args"]
  end

  test "GET test to bad host" do
    {:ok, response} = request(:get, "http://127.0.0.1:8080/manager/html")
    assert response.status_code == 503
  end

  # HTTParrot's /stream/:n endpoint will stream 
  # (with transfer-encoding: chunked) n response body objects.

  test "chunked response test" do
    num_streams = 87
    {:ok, response} = request_streaming_response(:get, "http://localhost:8080/stream/#{num_streams}")
    assert response.status_code == 200
    assert List.keyfind(response.headers, "transfer-encoding", 0) == {"transfer-encoding", "chunked"}
    assert length(response.chunks) == num_streams
  end

  test "small post test" do
    {:ok, response} = request(:post, "http://localhost:8080/post", [{"content-type", "text/plain"}], "test data")
    assert response.status_code == 200
    body = Poison.decode!(response.body)
    assert body["data"] == "test data"
  end

  test "big post test" do
    sixteen_meg_binary = Stream.repeatedly(fn -> @one_k_binary end)
                     |> Enum.take(16384)
                     |> Enum.join

    {:ok, response} = request_streaming_response(:post, "http://localhost:8080/post", [], sixteen_meg_binary)
    body = Enum.join(response.chunks)
    body = Poison.decode!(body)
    assert body["data"] == sixteen_meg_binary
  end

  test "big chunked post test" do
    # Since we're using an embedded HTTParrot, which in turn uses Cowboy,
    # we're stuck with the default cowboy limit of 8 MB on streaming requests.
    # Weirdly, cowboy doesn't limit the size of non-streaming requests...
    # ¯\_(ツ)_/¯
    four_meg_binary = Stream.repeatedly(fn -> @one_k_binary end)
                      |> Enum.take(4096)
                      |> Enum.join

    # Send three chunks
    binary_length = byte_size(four_meg_binary)
    chunk_size = byte_size(four_meg_binary) / 3 |> Float.ceil |> Kernel.trunc

    first_chunk = Kernel.binary_part(four_meg_binary, chunk_size * 0, chunk_size)
    second_chunk = Kernel.binary_part(four_meg_binary, chunk_size * 1, chunk_size)
    third_chunk = Kernel.binary_part(four_meg_binary, chunk_size * 2, binary_length - (chunk_size * 2))

    {:ok, client} = :hackney.request(:post, "http://localhost:8080/post", [{"transfer-encoding", "chunked"}, {"content-type", "text/plain"}], :stream, [])
    :ok = :hackney.send_body(client, first_chunk)
    :ok = :hackney.send_body(client, second_chunk)
    :ok = :hackney.send_body(client, third_chunk)
    {:ok, _status, _headers, client} = :hackney.start_response(client)
    {:ok, body} = :hackney.body(client)

    body = Poison.decode!(body)
    assert body["data"] == four_meg_binary
  end

  test "multipart/form-data test" do
    parts = [{"key1", "value1"}, {"key2", "value2"}]

    {:ok, response} = request(:post, "http://localhost:8080/post", [], {:multipart, parts})
    body = Poison.decode!(response.body)
    assert body["form"] == %{"key1" => "value1", "key2" => "value2"}
  end

  test "multipart/form-data test with small file upload" do
    {:ok, file_path} = build_tempfile("test", "test data")

    parts = [{"key1", "value1"}, {"key2", "value2"}, {:file, file_path, {"form-data", [{"name", "file1"}, {"filename", Path.basename(file_path)}]}, [{"content-type", "text/plain"}]}]

    {:ok, response} = request(:post, "http://localhost:8080/post", [], {:multipart, parts})

    body = Poison.decode!(response.body)

    assert body["form"] == %{"key1" => "value1", "key2" => "value2"}
    assert body["files"] == %{"file1" => "test data"}
  end

  test "multipart/form-data test with large file upload" do
    sixteen_meg_binary = Stream.repeatedly(fn -> @one_k_binary end)
                         |> Enum.take(16384)
                         |> Enum.join

    {:ok, file_path} = build_tempfile("test", sixteen_meg_binary)

    parts = [{"key1", "value1"}, {"key2", "value2"}, {:file, file_path, {"form-data", [{"name", "file1"}, {"filename", Path.basename(file_path)}]}, [{"content-type", "text/plain"}]}]

    {:ok, response} = request(:post, "http://localhost:8080/post", [], {:multipart, parts})

    body = Poison.decode!(response.body)

    assert body["form"] == %{"key1" => "value1", "key2" => "value2"}
    assert body["files"] == %{"file1" => sixteen_meg_binary}
  end

  test "204 return handling" do
    {:ok, response} = request(:get, "http://localhost:8080/status/204")
    assert response.status_code == 204
    assert response.body == ""
  end

  test "304 return handing" do
    {:ok, response} = request(:get, "http://localhost:8080/status/304")
    assert response.status_code == 304
    assert response.body == ""
  end

  test "x-openaperture-request-id" do
    {:ok, response} = request(:get, "http://localhost:8080/headers")
    body = Poison.decode!(response.body)
    headers = body["headers"]
    assert Map.has_key?(headers, "x-openaperture-request-id")
  end

  test "adds x-forwarded-for header if not present" do
    {:ok, response} = request(:get, "http://localhost:8080/headers")
    body = Poison.decode!(response.body)
    headers = body["headers"]
    assert Map.has_key?(headers, "x-forwarded-for")
  end

  test "does not add x-forwarded-for header if it's already present" do
    header_value = "Cool Test Value"
    {:ok, response} = request(:get, "http://localhost:8080/headers", [{"X-Forwarded-For", header_value}])
    body = Poison.decode!(response.body)
    headers = body["headers"]

    assert headers["x-forwarded-for"] == header_value
  end

  test "adds x-forwarded-host header if not present" do
    {:ok, response} = request(:get, "http://localhost:8080/headers")
    body = Poison.decode!(response.body)
    headers = body["headers"]
    assert Map.has_key?(headers, "x-forwarded-host")
  end

  test "does not add x-forwarded-host header if it's already present" do
    header_value = "Cool Test Value"
    {:ok, response} = request(:get, "http://localhost:8080/headers", [{"X-Forwarded-Host", header_value}])
    body = Poison.decode!(response.body)
    headers = body["headers"]

    assert headers["x-forwarded-host"] == header_value
  end

  test "adds x-forwarded-port header if not present" do
    {:ok, response} = request(:get, "http://localhost:8080/headers")
    body = Poison.decode!(response.body)
    headers = body["headers"]
    assert Map.has_key?(headers, "x-forwarded-port")
  end

  test "does not add x-forwarded-port header if it's already present" do
    header_value = "1234"
    {:ok, response} = request(:get, "http://localhost:8080/headers", [{"X-Forwarded-Port", header_value}])
    body = Poison.decode!(response.body)
    headers = body["headers"]

    assert headers["x-forwarded-port"] == header_value
  end

  test "adds x-forwarded-proto header if not present" do
    {:ok, response} = request(:get, "http://localhost:8080/headers")
    body = Poison.decode!(response.body)
    headers = body["headers"]
    assert Map.has_key?(headers, "x-forwarded-proto")
  end

  test "does not add x-forwarded-proto header if it's already present" do
    header_value = "https"
    {:ok, response} = request(:get, "http://localhost:8080/headers", [{"X-Forwarded-Proto", header_value}])
    body = Poison.decode!(response.body)
    headers = body["headers"]

    assert headers["x-forwarded-proto"] == header_value
  end

  test "strips out cowboy response headers" do
    server = "test_server"
    connection = "close"
    date = "Wed, 06 May 2015 19:11:15 GMT"
    transfer_encoding = "weird"

    query = "Server=" <> URI.encode(server) <> "&Connection=" <> URI.encode(connection) <> "&Date=" <> URI.encode(date) <> "&Transfer-Encoding=" <> URI.encode(transfer_encoding)
    {:ok, response} = request(:get, "http://localhost:8080/response-headers?" <> query)
    assert response.status_code == 200

    headers = response[:headers]

    assert {"server", "Cowboy"} in headers == false

    assert List.keyfind(headers, "Server", 0) == {"Server", server}
    assert List.keyfind(headers, "Connection", 0) == {"Connection", connection}
    assert List.keyfind(headers, "Date", 0) == {"Date", date}
    assert List.keyfind(headers, "Transfer-Encoding", 0) == {"Transfer-Encoding", transfer_encoding}
  end
end