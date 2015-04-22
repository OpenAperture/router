use Mix.Config

config :openaperture_router,
  env: :override_me,
  num_acceptors: 100,
  http_port: 8080,
  route_server_url: System.get_env("OPENAPERTURE_ROUTER_MANAGER_URL") || "http://localhost:4000/api/routes",
  route_server_ttl: 60_000

config :openaperture_router,
  connecting: 5_000,
  sending_request_body: 60_000,
  waiting_for_response: 60_000,
  receiving_response: 60_000

import_config "#{Mix.env}.exs"