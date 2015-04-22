defmodule OpenAperture.Router.RouteServer do
  @moduledoc """
  The RouteServer handles initializing and updated the ETS cache which
  contains the list of routes, as well as running an agent which maintains
  a timestamp indicating the last time the route list was updated.
  """

  @type unix_timestamp :: integer

  require Logger
  import OpenAperture.Router.Util

  @doc """
  This function starts the RouteServer agent, which contains state information
  indicating the last time routes were fetched (or nil if no fetch has been
  performed yet).
  It also starts a child process which loads any updated route information
  in an update loop.
  """
  @spec start_link() :: {:ok, pid} | {:error, String.t}
  def start_link do
    Logger.debug "Starting the RouteServer process #{inspect self}."

    # Just need a simple agent to keep track of the last time the routes were
    # updated.
    Agent.start_link(fn -> nil end, name: __MODULE__)

    # Try to load all the routes at startup
    spawn(fn -> load_all_routes end)

    updater_pid = spawn_link(fn -> update_routes end)

    {:ok, updater_pid}
  end

  @spec get_last_fetch_timestamp :: unix_timestamp
  def get_last_fetch_timestamp() do
    Agent.get(__MODULE__, &(&1))
  end

  # Loads *all* route information from the database and stores it in the ETS
  # cache. Updates the agent state with the time the initial load occurred, if
  # successful.
  def load_all_routes() do
    Logger.debug "Performing initial route load."

    case get_routes do
      {:ok, routes, timestamp} ->
        routes
        |> Enum.each(fn({authority, tuples}) ->
          # We can dirty put on initial load, because there won't be any routes
          # with matching keys...
          ConCache.dirty_put(:routes, authority, tuples)
        end)

        Agent.update(__MODULE__, fn _state -> timestamp end)

        Logger.debug "Initial route load completed."

      {:error, error} ->
        Logger.error "Error performing initial route load: #{inspect error}"
    end
  end

  # Checks the agent state for the last successful route update, and then loads
  # any route with an updated_at time newer than that. Updates the ETS cache
  # with the new routes.
  defp update_routes() do
    receive do
      # TODO: Make this value configurable...
    after routes_ttl() ->
      case get_last_fetch_timestamp() do
        nil ->
          # The initial load of routes failed for some reason. Try it now.
          Logger.debug "Cannot update routes -- initial route list has not yet been loaded."
          load_all_routes()

        timestamp ->
          case get_routes(timestamp) do
            {:ok, routes, new_timestamp} ->
              if length(routes) == 0 do
                Logger.debug "No updated routes since #{inspect timestamp}"
              else
                Logger.debug "Updated (or new) routes: #{length(routes)}"
                Enum.each(routes, fn ({authority, tuples}) ->
                  ConCache.put(:routes, authority, tuples)
                end)
              end

              Agent.update(__MODULE__, fn _state -> new_timestamp end)

              Logger.debug "Finished updating routes at #{inspect new_timestamp}"

            {:error, error} ->
              Logger.error "Error updating routes: #{inspect error}"
          end
      end
    end

    # Tail-call back into this function, setting up our update loop.
    update_routes()
  end

  @spec routes_url() :: String.t | nil
  defp routes_url() do
    Application.get_env(:openaperture_router, :route_server_url)
  end

  @spec routes_ttl() :: integer | nil
  defp routes_ttl() do
    Application.get_env(:openaperture_router, :route_server_ttl)
  end

  @spec get_routes() :: {:ok, [{String.t, tuple}], integer} | {:error, any}
  defp get_routes() do
    load_routes(routes_url)
  end

  @spec get_routes(integer) :: {:ok, [{String.t, tuple}], integer} | {:error, any}
  defp get_routes(timestamp) do
    load_routes("#{routes_url}?updated_since=#{timestamp}")
  end

  @spec load_routes(String.t) :: {:ok, [{String.t, tuple}], integer} | {:error, any}
  defp load_routes(routes_url) do
    Logger.info "Loading routes from #{routes_url}"
    case :hackney.get(routes_url, [get_auth_header], "", get_hackney_options(routes_url)) do
      {:ok, 200, _headers, client} ->
        case :hackney.body(client) do
          {:ok, body} ->
            case Poison.decode(body) do
              {:ok, %{"timestamp" => timestamp} = routes} ->
                routes = Map.delete(routes, "timestamp")
                         |> format_routes
                {:ok, routes, timestamp}

              {:ok, _other} ->
                Logger.error "Request for routes successful, but response body was missing 'timestamp' field."
                {:error, :no_timestamp}

              {:error, err} ->
                Logger.error "Request for routes successful, but response body could not be parsed: #{inspect err}"
                {:error, err}
            end

          other ->
            Logger.error "Error retrieving routes message body: #{inspect other}"
            {:error, other}
        end

      other ->
        Logger.error "Error making call to #{routes_url}: #{inspect other}"
        {:error, other}
    end
  end

  @spec format_routes([{String.t, Map.t}]) :: [{String.t, {String.t, integer, boolean}}]
  defp format_routes(routes) do
    Enum.map(routes, fn {authority, authority_routes} ->
      tuples = Enum.map(authority_routes, fn route ->
        {route["hostname"], route["port"], route["secure_connection"]}
      end)

      {authority, tuples}
    end)
  end

  @spec get_auth_header :: {String.t, String.t}
  defp get_auth_header() do
    #token = OpenAperture.Auth.Client.get_token("https://idp-staging.psft.co/oauth/token", "106b9b61ff7210bea54eb0328791c28fe95e274f076707c30f7614cc5e3242cc", "1e14aba66983a24fcad9fe56b053fd4e06114b54c44e137f014bd3541c29dded")
    #token = OpenAperture.Auth.Client.get_token("http://idp-staging.psft.co/oauth/token", Application.get_env(:openaperture_router, :client_id), Application.get_env(:openaperture_router, :client_secret))
    token = "abc"

    {"Authorization", "Bearer #{token}"}
  end
end