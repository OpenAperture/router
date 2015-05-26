use Mix.Config

config :openaperture_router,
  env: :prod,
  http_port: System.get_env("OPENAPERTURE_ROUTER_HTTP_PORT"),
  oauth_url: System.get_env("OPENAPERTURE_OAUTH_URL"),
  client_id: System.get_env("OPENAPERTURE_ROUTER_CLIENT_ID"),
  client_secret: System.get_env("OPENAPERTURE_ROUTER_CLIENT_SECRET"),
  route_server_url: System.get_env("OPENAPERTURE_ROUTER_MANAGER_URL")

config :logger, :console,
  level: :info