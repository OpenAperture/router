defmodule OpenAperture.Router.BackendRequestServer.Test do
  use ExUnit.Case
  use ShouldI

  import TestHelper

  alias OpenAperture.Router.BackendRequestServer

  with "no mock and a backend request server running" do
    setup context do
      {:ok, server_pid} = GenServer.start(BackendRequestServer, self)

      assign context, server_pid: server_pid
    end

    should "have a running backend request server process", context do
      assert Process.alive?(context[:server_pid])
    end

    should "be able to start a request", context do
      {result, _time} = BackendRequestServer.start_request(context[:server_pid], :get, get_httparrot_http_base_url, [], false)
      assert :ok == result
    end

    should "fail to start if the request cannot be started", context do
      {result, reason, _time} = BackendRequestServer.start_request(context[:server_pid], :get, "baddomain", [], false)
      assert result == :error
      assert reason == :nxdomain
    end

    test "blar", context do
      result = BackendRequestServer.start_request(context[:server_pid], :get, get_httparrot_http_base_url, [], false)
      IO.puts "result: #{inspect result}"
      #assert result == {:ok, _time}
    end

    should "receive a set of messages after making a request", context do
      pid = context[:server_pid]
      {result, _time} = BackendRequestServer.start_request(pid, :get, get_httparrot_http_base_url, [], false)
      assert result == :ok

      assert_receive({:backend_request_initial_response, ^pid, status, _reason, _headers})
      assert status == 200

      assert_receive({:backend_request_response_chunk, ^pid, _chunk})

      assert_receive({:backend_request_done, ^pid, _duration})
    end

    should "send request chunks from the client", context do
      pid = context[:server_pid]
      {result, _time} = BackendRequestServer.start_request(pid, :post, get_httparrot_http_base_url <> "/post", [{"content-type", "text/plain"}], true)
      assert result == :ok

      {result, _time} = BackendRequestServer.send_request_chunk(pid, "a chunk\n", false)
      assert result == :ok

      {result, _time} = BackendRequestServer.send_request_chunk(pid, "the last chunk\n", true)
      assert result == :ok

      assert_receive({:backend_request_initial_response, ^pid, status, _reason, _headers})
      assert status == 200

      assert_receive({:backend_request_response_chunk, ^pid, _chunk})
      assert_receive({:backend_request_done, ^pid, _duration})
    end

    should "send an error message if it receives a hackney error", context do
      pid = context[:server_pid]
      error = "An error message!!!!"
      send pid, {:hackney_response, :a_client_ref, {:error, error}}

      assert_receive({:backend_request_error, ^pid, ^error})
    end
  end

  with "mocks and a backend request server running" do
    setup context do
      :meck.new :hackney
      {:ok, server_pid} = GenServer.start(BackendRequestServer, self)

      on_exit fn -> :meck.unload end

      assign context, server_pid: server_pid
    end

    should "send a message and exit if hackney errors", context do
      :meck.expect(:hackney, :request, 5, {:error, :test_error_reason})

      {result, reason, _time} = BackendRequestServer.start_request(context[:server_pid], :get, "http://test.com", [], false)

      assert result == :error
      assert reason == :test_error_reason
    end

    with "a simple GET request" do
      setup context do
        :meck.expect(:hackney, :request, 5, {:ok, :client})
        {result, _time} = BackendRequestServer.start_request(context[:server_pid], :get, "http://url", [], false)
        assert result == :ok
        context
      end

      should "receive a message after initial connection is made", context do
        pid = context[:server_pid]
        headers = [{"content-type", "text/plain"}, {"favorite-color", "blue"}]
        send pid, {:hackney_response, :client, {:status, 200, "OK"}}
        send pid, {:hackney_response, :client, {:headers, headers}}

        assert_receive({:backend_request_initial_response, ^pid, 200, "OK", ^headers})
        assert Process.alive?(pid)
      end

      should "receive a response chunk and stay alive", context do
        chunk = "HEY LOOK AT ME I'M A CHUNK OF DATA WOW!! #WHOA"
        pid = context[:server_pid]

        send pid, {:hackney_response, :client, chunk}
        assert_receive({:backend_request_response_chunk, ^pid, ^chunk})
        assert Process.alive?(pid)
      end

      should "receive a response done message and shut down", context do
        pid = context[:server_pid]
        send pid, {:hackney_response, :client, :done}

        assert_receive({:backend_request_done, ^pid, _duration})
        # Give it a moment to shut down
        :timer.sleep(100)
        refute Process.alive?(pid)
      end

      should "receive a hackney error and stay alive", context do
        pid = context[:server_pid]
        error = "OH NO!"
        send pid, {:hackney_response, :client, {:error, error}}

        assert_receive({:backend_request_error, ^pid, ^error})
        assert Process.alive?(pid)
      end
    end

    with "a POST request with a body" do
      setup context do
        :meck.expect(:hackney, :request, 5, {:ok, :client})
        {result, _time} = BackendRequestServer.start_request(context[:server_pid], :post, "http://url", [{"content-type", "text/plain"}], false)
        assert result == :ok
        context
      end

      with "a non-final request body chunk" do
        should "send body chunks to the backend server and stay alive", context do
          :meck.expect(:hackney, :send_body, 2, :ok)
          pid = context[:server_pid]
          {result, _time} = BackendRequestServer.send_request_chunk(pid, "some chunk of data", false)
          assert result == :ok
          assert Process.alive?(pid)
        end

        should "return error response upon error sending chunk to the backend server and stay alive", context do
          error = "OH NO!"
          :meck.expect(:hackney, :send_body, 2, {:error, error})
          pid = context[:server_pid]
          {result, reason, _time} = BackendRequestServer.send_request_chunk(pid, "some chunk of data", false)
          assert result == :error
          assert reason == error
          assert Process.alive?(pid)
        end
      end

      with "a final request body chunk" do
        should "return error response upon error sending chunk to the backend server and stay alive", context do
          error = "OH NO!"
          :meck.expect(:hackney, :send_body, 2, {:error, error})
          pid = context[:server_pid]
          {result, reason, _time} = BackendRequestServer.send_request_chunk(pid, "some chunk of data", true)
          assert result == :error
          assert reason == error
          assert Process.alive?(pid)
        end

        should "return error if there's an error initiating the response", context do
          error = "OH NO!"
          :meck.expect(:hackney, :send_body, 2, :ok)
          :meck.expect(:hackney, :start_response, 1, {:error, error})
          pid = context[:server_pid]

          {result, reason, _time} = BackendRequestServer.send_request_chunk(pid, "the last chunk", true)
          assert result == :error
          assert reason == error
          assert Process.alive?(pid)
        end

        should "send final chunk and return :ok", context do
          :meck.expect(:hackney, :send_body, 2, :ok)
          :meck.expect(:hackney, :start_response, 1, {:ok, :client1})
          pid = context[:server_pid]

          {result, _time} = BackendRequestServer.send_request_chunk(pid, "the last chunk", true)
          assert result == :ok
          assert Process.alive?(pid)
        end
      end
    end
  end
end