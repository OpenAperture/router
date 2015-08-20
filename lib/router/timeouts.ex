defmodule OpenAperture.Router.Timeouts do
  @moduledoc """
  This module provides a from_env function to get timeouts information shared across multiple
  Modules.
  """

  @spec from_env :: map
  def from_env do
    # Read the timeouts info from the env config
    Application.get_env(:openaperture_router, :timeouts, [
      connecting:            5_000,
      sending_request_body:  60_000,
      waiting_for_response:  60_000,
      receiving_response:    60_000
      ])
  end
end
