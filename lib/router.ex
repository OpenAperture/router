defmodule OpenAperture.Router do
  use Application

  def start(_type, _args) do
    import Supervisor.Spec

    :random.seed(:erlang.now())

    dispatch = :cowboy_router.compile([{:_, [{:_, OpenAperture.Router.HttpHandler, []}]}])
    http_proto_opts = [{:env, [{:dispatch, dispatch}]}, {:onresponse, &OpenAperture.Router.HttpHandler.on_response/4}]

    # TODO: Move the # of acceptors and port into env vars. Currently
    # hardcoded to 100 and 8080.

    # Ranch documentation suggests that 100 is a good default for num_acceptors:
    # http://ninenines.eu/docs/en/ranch/1.1/guide/internals/
    # "Our observations suggest that using 100 acceptors on modern hardware is a good solution"
    {:ok, _cowboy_pid} = :cowboy.start_http(:router, 100, [{:port, 8080}], http_proto_opts)

    children = [
      # Start up ConCache, set ttl to zero so items won't expire.
      worker(ConCache, [[ttl: 0], [name: :routes]]),

      # The RouteServer is the process that handles keeping the :routes cache
      # up-to-date.
      worker(OpenAperture.Router.RouteServer, [])
    ]

    Supervisor.start_link(children, [strategy: :one_for_one, name: OpenAperture.Router.Supervisor])
  end
end