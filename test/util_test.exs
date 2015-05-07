defmodule OpenAperture.Router.Util.Test do
  use ExUnit.Case, async: false
  doctest OpenAperture.Router.Util

  import OpenAperture.Router.Util

  test "erlang_timestamp_to_unix_timestamp" do
    now = :os.timestamp

    now_unix = erlang_timestamp_to_unix_timestamp(now)

    assert div(now_unix, 1_000_000) == elem(now, 0)
    assert rem(now_unix, 1_000_000) == elem(now, 1)
  end

  test "get authority with path" do
    url = "https://test.app.com:80/some/path?query=string"
    assert get_authority_from_url(url) == "test.app.com:80"
  end

  test "get host from url with no path" do
    url = "http://test:80"
    assert get_authority_from_url(url) == "test:80"
  end

  test "get host from url with no port" do
    url = "https://test/some/path?query"
    assert get_authority_from_url(url) == "test"
  end

  test "get host from url with no port and no path" do
    url = "https://test"
    assert get_authority_from_url(url) == "test"
  end

  test "get host from invalid url returns nil" do
    url = "notvalid"
    assert get_authority_from_url(url) == nil
  end

  test "get hackney options - no config set" do
    assert get_hackney_options("http://yahoo.com") == []
  end

  test "get hackney options - config set" do
    Application.put_env(:openaperture_router, :hackney_config, [:setting, :value])

    assert get_hackney_options("http://yahoo.com") == [:setting, :value]

    Application.delete_env(:openaperture_router, :hackney_config)
  end

  test "get hackney options - config set, https url" do
    Application.put_env(:openaperture_router, :hackney_config, [:setting, :value])

    assert get_hackney_options("https://yahoo.com") == []

    Application.delete_env(:openaperture_router, :hackney_config)
  end

  test "get hackney options - config set, localhost url" do
    Application.put_env(:openaperture_router, :hackney_config, [:setting, :value])

    assert get_hackney_options("http://localhost/some/path") == []

    Application.delete_env(:openaperture_router, :hackney_config)
  end

  test "get hackney options - config set, lvh.me url" do
    Application.put_env(:openaperture_router, :hackney_config, [:setting, :value])

    assert get_hackney_options("http://lvh.me/some/path") == []

    Application.delete_env(:openaperture_router, :hackney_config)
  end

  test "get hackney options - config set, 127.0.0.1 url" do
    Application.put_env(:openaperture_router, :hackney_config, [:setting, :value])

    assert get_hackney_options("http://127.0.0.1/some/path") == []

    Application.delete_env(:openaperture_router, :hackney_config)
  end

  test "erlang_timestamp_to_microseconds" do
    now = :erlang.now()
    {megas, secs, micros} = now

    megas = megas
            |> Integer.to_string
            |> String.rjust(6, ?0)
    secs = secs
           |> Integer.to_string
           |> String.rjust(6, ?0)
    micros = micros
             |> Integer.to_string
             |> String.rjust(6, ?0)

    int = String.to_integer("#{megas}#{secs}#{micros}")

    assert erlang_timestamp_to_microseconds(now) == int
  end

  test "microseconds_to_erlang_timestamp" do
    now = :erlang.now
    {megas, secs, micros} = now

    megas = megas
            |> Integer.to_string
            |> String.rjust(6, ?0)
    secs = secs
           |> Integer.to_string
           |> String.rjust(6, ?0)
    micros = micros
             |> Integer.to_string
             |> String.rjust(6, ?0)

    int = String.to_integer("#{megas}#{secs}#{micros}")

    assert microseconds_to_erlang_timestamp(int) == now
  end
end