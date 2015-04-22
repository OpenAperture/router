use Mix.Config

config :openaperture_router,
  env: :prod,
  http_port: System.get_env("OPENAPERTURE_ROUTER_HTTP_PORT")

config :logger, :console,
  level: :info