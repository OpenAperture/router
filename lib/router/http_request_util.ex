defmodule OpenAperture.Router.HttpRequestUtil do
  @moduledoc """
  This module contains purely-functional helper functions for retrieving
  data from a cowboy request tuple and formatting in a way the router can use.
  """

  @type cowboy_req :: tuple
  @type headers :: [{String.t, String.t}]
  @doc """
  The :cowboy_req module's "method" function returns the HTTP verb used on an
  incoming request as a string. We need it in the form of an atom, so this
  function handles that conversion for us. For the time being, non-standard
  HTTP verbs are returned as strings, since we cannot (safely) automatically
  convert them to atoms.
  """
  @spec get_request_method(cowboy_req) :: {atom, CowboyReq} | {String.t, CowboyReq}
  def get_request_method(req) do
    {method, req} = :cowboy_req.method(req)

    method = case String.upcase(method) do
          "DELETE" -> :delete
          "GET" -> :get
          "HEAD" -> :head
          "OPTIONS" -> :options
          "PATCH" -> :patch
          "POST" -> :post
          "PUT" -> :put
          _ -> 
            # TODO: Figure out how we want to handle non-standard verbs.
            # We'll probably have to do something whitelist-based. We
            # **MUST NOT** just call `String.to_atom\1`, for reasons outlined
            # here: http://elixir-lang.org/getting_started/mix_otp/3.html
            # For now, just return the string as-is.
            method
        end

    {method, req}
  end

  @doc """
  The key feature of the router's reverse-proxying ability is taking a request
  to http://[public hostname]:[public port]/path?querystring and forwarding it
  to http://[backend hostname]:[backend port]/path?querystring.
  This function takes the original request URL's host and port and replaces 
  them with the backend's host and port, as well as specifying if the backend
  request needs to be made via https or http.
  """
  @spec get_backend_url(cowboy_req, String.t, integer, boolean) :: {atom, CowboyReq}
  def get_backend_url(req, backend_host, backend_port, https? \\ false) do
    {host_url, req} = :cowboy_req.host_url(req)
    {url, req} = :cowboy_req.url(req)

    proto = if https? do
      "https"
    else
      "http"
    end

    new_url = Regex.replace(~r/^#{host_url}/, url, "#{proto}://#{backend_host}:#{backend_port}")
    {new_url, req}
  end

  # Checks if the header map contains a key named "Transfer-Encoding",
  # and if so, if its value matches "chunked".
  @spec chunked_request?(headers) :: boolean
  def chunked_request?(headers) do
    headers
      |> Enum.any?(fn {key, value} ->
        # We have to do a case-insensitive check, because although the RFC states
        # that headers should be all lowercase, many servers send it as 
        # "Transfer-Encoding".
        if String.downcase(key) == "transfer-encoding" do
          # If there is a transfer-encoding header, check if its value matches
          # "chunked". Again, we convert to lowercase in case the server sends
          # it in some non-standard form.
          String.downcase(value) == "chunked"
        else
          false
        end
      end)
  end

  # Finds the first "content-length" or "transfer-encoding" header and returns
  # it. Returns nil if neither were found.
  @spec get_content_length_or_transfer_encoding(headers) :: {String.t, String.t} | nil
  def get_content_length_or_transfer_encoding(headers) do
    headers
    |> Enum.find(fn {key, _val} ->
      key = String.downcase(key)
      key == "content-length" || key == "transfer-encoding"
    end)
  end
end