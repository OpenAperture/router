use Mix.Config

config :openaperture_router,
  env: :dev,
  oauth_url: System.get_env("OPENAPERTURE_OAUTH_URL"),
  client_id: System.get_env("OPENAPERTURE_ROUTER_CLIENT_ID"),
  client_secret: System.get_env("OPENAPERTURE_ROUTER_CLIENT_SECRET"),
  route_server_url: System.get_env("OPENAPERTURE_ROUTER_MANAGER_URL") || "http://localhost:4000/router/routes",
  route_server_ttl: 30_000
  
config :logger, :console,
  level: :debug