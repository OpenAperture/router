defmodule OpenAperture.Router.Mixfile do
  use Mix.Project

  @version "0.0.1"

  def project do
    [app: :openaperture_router,
     version: get_version,
     elixir: "~> 1.0",
     deps: deps,
     test_coverage: [tool: ExCoveralls]]
  end

  # Generate a project version with the first 10 characters of the commit hash.
  # This is done so that new releases can be built even if the @version
  # attribute hasn't been bumped.
  defp get_version do
    commit_hash  = :os.cmd('git rev-parse HEAD') |> List.to_string |> String.slice(0..9)
    "#{@version}-#{commit_hash}"
  end

  def application do
    [
      mod: { OpenAperture.Router, [] },
      applications: [:logger, :cowboy, :hackney, :con_cache, :poison, :openaperture_auth]
    ]
  end

  defp deps do
    [
      {:cowboy, "1.0.0"},
      {:hackney, "1.0.6"},
      {:con_cache, "0.7.0"},
      {:exrm, "0.14.17"},
      {:uuid, "0.1.5"},
      {:poison, "1.3.1"},
      {:httparrot, github: "edgurgel/httparrot"},
      {:meck, "0.8.2", only: :test},
      {:openaperture_auth, github: "OpenAperture/auth"},
      {:shouldi, "0.2.1", only: :test},
      {:excoveralls, "~>0.3.9", only: :test}
    ]
  end
end