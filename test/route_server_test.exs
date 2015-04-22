defmodule OpenAperture.Router.RouteServer.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.RouteServer
  import OpenAperture.Router.Util

  setup do
    :meck.new :hackney

    Agent.update(OpenAperture.Router.RouteServer, fn _s -> nil end)

    # Clear out the route cache
    ConCache.get_all(:routes)
    |> Enum.each(fn {key, _val} ->
      ConCache.delete(:routes, key)
    end)

    on_exit fn -> :meck.unload end
  end

  test "load_all_routes -- success" do
    timestamp = erlang_timestamp_to_unix_timestamp(:os.timestamp)
    resp_body = """
    {"test:80":[
      {"secure_connection":false,
      "port":80,
      "hostname":"east.test"}],
      "timestamp":#{timestamp}}
    """

    :meck.expect(:hackney, :get, [{[:_, :_, :_, :_], {:ok, 200, [], :client}}])
    :meck.expect(:hackney, :body, [{[:client], {:ok, resp_body}}])

    assert :ok == load_all_routes

    routes = ConCache.get_all(:routes)

    assert length(routes) == 1
    route = List.first(routes)

    assert elem(route, 0) == "test:80"

    backend_routes = elem(route, 1)
    backend_route = List.first(backend_routes)

    assert elem(backend_route, 0) == "east.test"
    assert elem(backend_route, 1) == 80
    assert elem(backend_route, 2) == false

    ts = Agent.get(OpenAperture.Router.RouteServer, fn state -> state end)

    assert ts == timestamp
  end

  test "load_all_routes -- successful request, empty response body" do
    :meck.expect(:hackney, :get, [{[:_, :_, :_, :_], {:ok, 200, [], :client}}])
    :meck.expect(:hackney, :body, [{[:client], {:ok, ""}}])

    assert :ok == load_all_routes

    assert ConCache.get_all(:routes) == []

    ts = Agent.get(OpenAperture.Router.RouteServer, fn state -> state end)

    assert ts == nil
  end

  test "load_all_routes -- successful request, no timestamp in response body" do
    resp_body = """
    {"test:80":[
      {"secure_connection":false,
      "port":80,
      "hostname":"east.test"}]}
    """

    :meck.expect(:hackney, :get, [{[:_, :_, :_, :_], {:ok, 200, [], :client}}])
    :meck.expect(:hackney, :body, [{[:client], {:ok, resp_body}}])

    assert :ok == load_all_routes

    assert ConCache.get_all(:routes) == []

    ts = Agent.get(OpenAperture.Router.RouteServer, fn state -> state end)

    assert ts == nil
  end

  test "load_all_routes -- successful request, invalid response body" do
    :meck.expect(:hackney, :get, [{[:_, :_, :_, :_], {:ok, 200, [], :client}}])
    :meck.expect(:hackney, :body, [{[:client], {:ok, "not valid json"}}])

    assert :ok == load_all_routes

    assert ConCache.get_all(:routes) == []

    ts = Agent.get(OpenAperture.Router.RouteServer, fn state -> state end)

    assert ts == nil
  end

  test "load_all_routes -- unsuccessful request" do
    :meck.expect(:hackney, :get, [{[:_, :_, :_, :_], {:ok, 503, [], :client}}])

    assert :ok == load_all_routes

    assert ConCache.get_all(:routes) == []

    ts = Agent.get(OpenAperture.Router.RouteServer, fn state -> state end)

    assert ts == nil
  end
end