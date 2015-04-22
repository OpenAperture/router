defmodule OpenAperture.Router.BackendRequest.Test do
  use ExUnit.Case
  use ShouldI

  with "meck setup" do
    setup context do
      :meck.new :hackney

      on_exit fn -> :meck.unload end

      context
    end

    should "send message and exit if hackney errors" do
      :meck.expect(:hackney, :request, 5, {:error, :test_error_reason})

      br_pid = spawn(OpenAperture.Router.BackendRequest, :make_request, [self, :get, "http://url", []])

      assert_receive {:error, ^br_pid, :test_error_reason, _duration}
      refute Process.alive?(br_pid)
    end

    with "a simple GET request" do
      setup context do
        :meck.expect(:hackney, :request, 5, {:ok, :client})

        pid = spawn(OpenAperture.Router.BackendRequest, :make_request, [self, :get, "http://url", []])

        # Wait 100 ms for the response handler process to be spun up
        :timer.sleep(100)

        response_handler_pid = Process.info(pid)
                               |> Keyword.get(:links)
                               |> List.first

        send(pid, {:response_got_initial_response, response_handler_pid, {200, "OK", [:a_list_of_headers]}})
        send(pid, {:got_response_chunk, response_handler_pid, "a chunk"})

        assign context,
          backend_request_pid: pid,
          response_handler_pid: response_handler_pid
      end

      should "receive a :connected message and stay alive", context do
        pid = context[:backend_request_pid]
        assert_receive {:connected, ^pid, false}

        assert Process.alive?(context[:backend_request_pid])
      end

      should "send an initial response message and not exit", context do
        pid = context[:backend_request_pid]
        assert_receive {:initial_response, ^pid, {200, "OK", [:a_list_of_headers]}, _duration}

        assert Process.alive?(context[:backend_request_pid])
      end

      should "send the chunk to the parent and not exit", context do
        pid = context[:backend_request_pid]
        assert_receive {:response_chunk, ^pid, "a chunk"}

        assert Process.alive?(context[:backend_request_pid])
      end

      with "a done message from the response handler" do
        setup context do
          send(context[:backend_request_pid], {:got_response_done, context[:response_handler_pid]})

          context
        end

        should "send a done message to the parent and exit", context do
          pid = context[:backend_request_pid]
          assert_receive {:response_done, ^pid, _duration}

          refute Process.alive?(context[:backend_request_pid])
        end
      end

      with "an error message from the response handler" do
        setup context do
          send(context[:backend_request_pid], {:response_error, context[:response_handler_pid], :error,})

          context
        end

        should "send an error message and exit", context do
          pid = context[:backend_request_pid]
          assert_receive {:error, ^pid, :error, _duration}

          refute Process.alive?(context[:backend_request_pid])
        end
      end
    end

    with "a POST request with a body" do
      setup context do
        :meck.expect(:hackney, :request, 5, {:ok, :client})

        pid = spawn(OpenAperture.Router.BackendRequest, :make_request, [self, :post, "http://url", [{"content-length", "13"}]])

        # Wait 100 ms for the response handler process to be spun up
        :timer.sleep(100)

        response_handler_pid = Process.info(pid)
                               |> Keyword.get(:links)
                               |> List.first

        assign context,
          backend_request_pid: pid,
          response_handler_pid: response_handler_pid
      end

      with "a regular request body chunk" do
        should "send body chunks to the backend server and keeps processing running", context do
          pid = context[:backend_request_pid]
          :meck.expect(:hackney, :send_body, 2, :ok)
          send(context[:backend_request_pid], {:request_body_chunk, self, "Hello, World!"})

          assert_receive {:ready_for_body, ^pid}
          assert Process.alive?(pid)
        end

        should "send error message and quit if there's an error sending a chunk to the backend server", context do
          pid = context[:backend_request_pid]
          :meck.expect(:hackney, :send_body, 2, {:error, :reason})
          send(pid, {:request_body_chunk, self, "Hello, World!"})

          assert_receive {:error, ^pid, :reason, _duration}
          refute Process.alive?(pid)
        end
      end

      with "a final body chunk" do
        should "send error message and quit if there's an error sending the final chunk to the backend server", context do
          pid = context[:backend_request_pid]
          :meck.expect(:hackney, :send_body, 2, {:error, :reason})
          send(pid, {:final_body_chunk, self, "Hello, World!"})

          assert_receive {:error, ^pid, :reason, _duration}
          refute Process.alive?(pid)
        end

        should "send final body chunk and initiate response, send parent waiting_for_response message", context do
          pid = context[:backend_request_pid]
          :meck.expect(:hackney, :send_body, 2, :ok)
          :meck.expect(:hackney, :start_response, 1, {:ok, :client})

          send(context[:backend_request_pid], {:final_body_chunk, self, "Hello, World!"})

          assert_receive {:waiting_for_response, ^pid}
          assert Process.alive?(pid)
        end

        should "send final body chunk and initiate response, sending parent error message and exiting if initiating response fails", context do
          pid = context[:backend_request_pid]
          :meck.expect(:hackney, :send_body, 2, :ok)
          :meck.expect(:hackney, :start_response, 1, {:error, :reason})

          send(context[:backend_request_pid], {:final_body_chunk, self, "Hello, World!"})

          assert_receive {:error, ^pid, :reason, _duration}
          :timer.sleep(100) # wait a bit for the VM to settle down
          refute Process.alive?(pid)
        end
      end
    end
  end
end