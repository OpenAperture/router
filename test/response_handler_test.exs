defmodule OpenAperture.Router.ResponseHandler.Test do
  use ExUnit.Case

  setup context do
    rh_pid = spawn(OpenAperture.Router.ResponseHandler, :init, [self])

    on_exit context, fn ->
      if Process.alive?(rh_pid), do: Process.exit(rh_pid, :normal)
    end

    {:ok, pid: rh_pid}
  end

  test "On error, sends error to parent and exits", context do
    rh_pid = context[:pid]

    send(rh_pid, {:hackney_response, :client, {:error, :some_error}})

    assert_receive {:response_error, ^rh_pid, :some_error}

    refute Process.alive?(rh_pid)
  end

  test "on done message, sends done to parent and exits", context do
    rh_pid = context[:pid]

    send(rh_pid, {:hackney_response, :client, :done})

    assert_receive {:got_response_done, ^rh_pid}

    refute Process.alive?(rh_pid)
  end

  test "on status message, does not send message to parent, does not exit", context do
    rh_pid = context[:pid]

    send(rh_pid, {:hackney_response, :client, {:status, 200, "OK"}})

    refute_receive(_any_message)

    assert Process.alive?(rh_pid)
  end

  test "on headers message, sends message to parent, does not exit", context do
    rh_pid = context[:pid]

    send(rh_pid, {:hackney_response, :client, {:headers, [:a_list_of_headers]}})

    assert_receive {:response_got_initial_response, ^rh_pid, {nil, nil, [:a_list_of_headers]}}

    assert Process.alive?(rh_pid)
  end

  test "on response chunk, sends chunk to parent, does not exit", context do
    rh_pid = context[:pid]

    send(rh_pid, {:hackney_response, :client, "a chunk"})

    assert_receive {:got_response_chunk, ^rh_pid, "a chunk"}

    assert Process.alive?(rh_pid)
  end

  test "full workflow", context do
    rh_pid = context[:pid]

    now = :erlang.now()

    send(rh_pid, {:reset_timer, self})

    send(rh_pid, {:hackney_response, :client, {:status, 200, "OK"}})

    send(rh_pid, {:hackney_response, :client, {:headers, [:a_list_of_headers]}})

    assert_receive {:response_got_initial_response, ^rh_pid, {200, "OK", [:a_list_of_headers]}}

    send(rh_pid, {:hackney_response, :client, "a chunk"})

    assert_receive {:got_response_chunk, ^rh_pid, "a chunk"}

    send(rh_pid, {:hackney_response, :client, :done})

    _duration = :timer.now_diff(:erlang.now(), now)

    assert_receive {:got_response_done, ^rh_pid}

    refute Process.alive?(rh_pid)
  end
end