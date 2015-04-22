OpenAperture Router
================
[![Build Status](https://semaphoreci.com/api/v1/projects/bf27c47e-9911-47a3-ae93-2cfd9d645c88/406002/badge.svg)](https://semaphoreci.com/perceptive/router)

This is a fast HTTP reverse proxy using Cowboy to handle incoming HTTP connections, and ETS for route lookup.

The router retrieves its list of routes via webservice call to a running instace of the [OpenAperture Router Manager](https://github.com/OpenAperture/router-manager). If you wish to change the list of routes the router uses (for development purposes, for example), you may run your own copy of the router manager, and change the application configuration to point to your instance, via the `OPENAPERTURE_ROUTER_MANAGER_URL` environmental variable.

The normal elixir project setup steps are required:

    mix do deps.get, deps.compile

Then you can start the router with

    iex -S mix