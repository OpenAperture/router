defmodule OpenAperture.Router.HttpHandler.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.Util

  setup do
    # Add a small sleep so the test doesn't shut down before the router
    # gets a chance to handle the `terminate` callback from cowboy.
    on_exit fn -> :timer.sleep(100) end
  end

  setup_all do
    Application.put_env(:httparrot, :http_port, 4007, persistent: true)
    {:ok, _} = :application.ensure_all_started(:httparrot)

    # Add a host:port->route_host:port mapping for our httparrot server
    ConCache.put(:routes, "localhost:8080", [{"localhost", 4007, false}])
    :ok
  end

  test "handle status request, no routes loaded yet should return 503" do
    clear_route_cache()

    Agent.update(OpenAperture.Router.RouteServer, fn _state -> nil end)
    {:ok, status_code, _headers, _client} = :hackney.get("http://localhost:8080/openaperture_router_status_check")

    assert status_code == 503
  end

  test "handle status request, no routes fetched in last 10 minutes should return 503" do
    old_timestamp = :os.timestamp
         |> erlang_timestamp_to_unix_timestamp
         |> (fn ts -> ts - 601 end).() # subtract 601 seconds

    # Set the RouteServer agent state to the timestamp from 10 minutes ago
    Agent.update(OpenAperture.Router.RouteServer, fn _state -> old_timestamp end)

    {:ok, status_code, _header, _client} = :hackney.get("http://localhost:8080/openaperture_router_status_check")

    assert status_code == 503
  end

  test "handle status request, routes loaded recently" do
    # Set the RouteServer agent state to the timestamp from 30 seconds ago
    Agent.update(OpenAperture.Router.RouteServer, fn _state -> get_recent_timestamp end)

    {:ok, status_code, _header, _client} = :hackney.get("http://localhost:8080/openaperture_router_status_check")

    assert status_code == 200
  end

  defp get_recent_timestamp() do
    :os.timestamp
    |> erlang_timestamp_to_unix_timestamp
    |> (fn ts -> ts - 30 end).() # subtract 30 seconds
  end

  defp clear_route_cache() do
    # Clear out the route cache
    ConCache.get_all(:routes)
    |> Enum.each(fn {key, _val} ->
      ConCache.delete(:routes, key)
    end)
  end
end