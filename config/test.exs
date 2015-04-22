use Mix.Config

config :openaperture_router,
  env: :test,
  route_server_ttl: 60_000


### Comment this section out if you have failing tests you want to debug...
config :logger,
  backends: []