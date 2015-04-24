ExUnit.start()

{:ok, _} = Application.ensure_all_started(:httparrot)

defmodule TestHelper do
  def get_httparrot_http_base_url() do
    "http://localhost:#{Application.get_env(:httparrot, :http_port)}"
  end

  def get_httparrot_https_base_url() do
    "http://localhost:#{Application.get_env(:httparrot, :https_port)}"
  end
end