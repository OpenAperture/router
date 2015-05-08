defmodule OpenAperture.Router.RouteCache.Test do
  use ExUnit.Case, async: false

  import OpenAperture.Router.RouteCache

  setup do
    ConCache.delete(:routes, "test_host:80")
  end

  test "get route for authority -- no routes in cache" do
    result = get_route_for_authority("test_host", 80, "/")
    assert result == nil
  end

  test "get route for authority -- one route in cache" do
    ConCache.put(:routes, "test_host:80", [{"west.test", 80, false}])

    result = get_route_for_authority("test_host", 80, "/")
    assert result == {"west.test", 80, false}
  end

  test "get route for authority -- multiple routes in cache" do
    routes = [
      {"west.test", 80, false},
      {"east.test", 80, false}
    ]

    ConCache.put(:routes, "test_host:80", routes)

    result = get_route_for_authority("test_host", 80, "/")

    assert result in routes
  end
end