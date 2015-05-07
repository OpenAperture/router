defmodule OpenAperture.Router.Types do
  @moduledoc """
  This module just contains type definitions for types which are shared
  between multiple modules in the router.
  """

  @type cowboy_req :: tuple
  @type headers :: [{String.t, String.t}]
  @type microseconds :: integer
  @type erlang_timestamp :: {MegaSecs, Secs, MicroSecs}
  @type unix_timestamp :: integer
end