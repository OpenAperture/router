defmodule OpenAperture.Router.Types do
  @moduledoc """
  This module just contains type definitions for types which are shared
  between multiple modules in the router.
  """

  @typedoc """
  The Cowboy Request "object" is essentially a big tuple.
  http://ninenines.eu/docs/en/cowboy/1.0/guide/req/
  """
  @type cowboy_req :: tuple

  @typedoc """
  Headers come in the form [{"header name", "header value"}]. While header
  names are case-insensitive, Cowboy really likes them to be lower-cased. This
  actually leads to a problem with Cowboy inserting it's own version of certain
  headers (like connection, date, server, transfer-encoding) if the headers we
  supply from the back end are upper-cased.
  """
  @type headers :: [{String.t, String.t}]

  @typedoc """
  All request timing is done in microseconds.
  """
  @type microseconds :: integer

  @typedoc """
  An erlang timestamp is a three-element tuple of the form
  {Megas, Secs, Micros} where Megas are seconds * 1,000,000, Secs are normal
  seconds, and micros are Secs / 1,000,000.
  """
  @type erlang_timestamp :: {integer, integer, integer}

  @typedoc """
  A typical unix timestamp, number of seconds since midnight, January 1, 1970.
  """
  @type unix_timestamp :: integer

  @typedoc """
  A route is three-element tuple containing a hostname, port, and a flag
  indicating whether connections should be made securely (i.e. via https).
  """
  @type route :: {String.t, integer, boolean}
end