defmodule OpenAperture.Router.Util do
  @moduledoc """
  This module contains purely-functional utility functions that may be used
  throughout the router
  """

  alias OpenAperture.Router.Types

  @mega 1_000_000

  @doc """
  Converts an erlang timestamp to a unix timestamp. Erlang timestamps are of
  the form {MegaSecs, Secs, MicroSecs}, of the elapsed time since the start of
  the Unix epoch. See http://erlang.org/doc/man/erlang.html#now-0 for more
  details on Erlang timestamps. Unix timestamps are an integer representing the
  number of seconds since the start of the Unix epoch.

  This conversion is necessarily lossy, since Unix timestamps have only one
  second resolution, while Erlang timestamps have microsecond resolution.
  """
  @spec erlang_timestamp_to_unix_timestamp(Types.erlang_timestamp) :: Types.unix_timestamp
  def erlang_timestamp_to_unix_timestamp(erlang_timestamp) do
    # Unix time only counts seconds, disregard microseconds
    {mega, secs, _} = erlang_timestamp

    mega * @mega + secs
  end

  @doc """
  Converts an erlang timestamp into an integer representing the total number of
  microseconds contained in the timestamp.

  ## Example

      iex> OpenAperture.Router.Util.erlang_timestamp_to_microseconds({1423, 865182, 571806})
      1423865182571806
  """
  @spec erlang_timestamp_to_microseconds(Types.erlang_timestamp) :: integer
  def erlang_timestamp_to_microseconds({megaSecs, secs, microSecs}) do
    megaSecs * @mega * @mega + secs * @mega + microSecs
  end

  @doc """
  Converts an integer representing a certain number of microseconds into an
  erlang timestamp.

  ## Example

      iex> OpenAperture.Router.Util.microseconds_to_erlang_timestamp(1423865182571806)
      {1423,865182,571806}
  """
  @spec microseconds_to_erlang_timestamp(integer) :: Types.erlang_timestamp
  def microseconds_to_erlang_timestamp(integer) do
    megas = div(integer, @mega * @mega)
    secs = integer
           |> div(@mega)
           |> rem(@mega)
    micros = rem(integer, @mega)

    {megas, secs, micros}
  end

  @doc """
  Extracts the authority (hostname and port, if specified) from a URL.

  ## Examples

      iex> OpenAperture.Router.Util.get_authority_from_url "https://test.myapp.com:80/some/path?query=string"
      "test.myapp.com:80"

      iex> OpenAperture.Router.Util.get_authority_from_url "^not&a*valid%url"
      nil

  """
  @spec get_authority_from_url(String.t) :: String.t | nil
  def get_authority_from_url(url) do
    regex = ~r/^(.+):\/\/(?<authority>[^\/]+)(\/.*)*/

    regex
    |> Regex.named_captures(url)
    # Regex.named_captures returns nil instead of an empty map if no captures
    # were made, but we need to at least pass an empty map to Map.get.
    |> (&(if &1 == nil, do: %{}, else: &1)).()
    |> Map.get("authority")
  end

  @doc """
  Checks if any hackney options (almost certainly a proxy config) has been set
  in the environment configuration, and checks that the url about to be called
  isn't one that shouldn't use the proxy (i.e. a local url).
  """
  @spec get_hackney_options(String.t) :: [] | [{String.t, integer}]
  def get_hackney_options(url) do
    case Application.get_env(:openaperture_router, :hackney_config, []) do
      [] -> []
      conf ->
        # Check if we're hitting a local endpoint, in which case we can't use
        # the proxy
        cond do
          String.starts_with?(url, "https")            -> []
          String.starts_with?(url, "http://localhost") -> []
          String.starts_with?(url, "http://127.0.0.1") -> []
          String.starts_with?(url, "http://lvh.me")    -> []
          true                                         -> conf
        end
    end
  end
end
