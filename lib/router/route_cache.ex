defmodule OpenAperture.Router.RouteCache do
  @moduledoc """
  This module contains functions for adding, removing, and retrieving routes
  in the route cache.
  """

  require Logger

  @doc """
  Retrieve a route for the specified authority (hostname and port) using the
  default algorithm.
  """
  @spec get_route_for_authority(String.t, integer, String.t) :: {String.t, integer, boolean} | nil
  def get_route_for_authority(host, port, path) do
    # For now we'll just randomly pick a backend route to route to...
    get_route_for_authority(host, port, path, :random)
  end

  @spec get_route_for_authority(String.t, integer, String.t, :random) :: {String.t, integer, boolean}
  defp get_route_for_authority(host, port, _path, :random) do
    routes = ConCache.get(:routes, "#{host}:#{port}")
    Logger.debug "Routes matching #{host}:#{port}: #{inspect routes}"

    case routes do
      nil          -> nil
      [route | []] -> route
      routes ->
        index = :random.uniform(length(routes)) - 1
        Enum.at(routes, index)
    end
  end
end
