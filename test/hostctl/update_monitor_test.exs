defmodule Hostctl.UpdateMonitorTest do
  use ExUnit.Case, async: false

  test "caches availability, retains it after a failed check, and clears it after a successful current check" do
    Phoenix.PubSub.subscribe(Hostctl.PubSub, "update_status")

    responses =
      start_supervised!(
        {Agent,
         fn -> [{:ok, %{has_update: true}}, {:error, :offline}, {:ok, %{has_update: false}}] end}
      )

    checker = fn -> Agent.get_and_update(responses, fn [result | rest] -> {result, rest} end) end

    monitor =
      start_supervised!({Hostctl.UpdateMonitor, name: nil, checker: checker, enabled: false})

    GenServer.cast(monitor, :check)

    assert_receive {:update_status, %{available?: true, status: :ok, last_success_at: checked}},
                   1000

    GenServer.cast(monitor, :check)

    assert_receive {:update_status,
                    %{available?: true, status: :error, last_success_at: ^checked}},
                   1000

    GenServer.cast(monitor, :check)
    assert_receive {:update_status, %{available?: false, status: :ok}}, 1000
    assert GenServer.call(monitor, :snapshot).available? == false
  end

  test "coalesces concurrent checks" do
    parent = self()

    checker = fn ->
      send(parent, {:checking, self()})

      receive do
        :finish -> {:ok, %{has_update: false}}
      end
    end

    monitor =
      start_supervised!({Hostctl.UpdateMonitor, name: nil, checker: checker, enabled: false})

    GenServer.cast(monitor, :check)
    assert_receive {:checking, worker}
    GenServer.cast(monitor, :check)
    _ = :sys.get_state(monitor)
    refute_receive {:checking, _}
    send(worker, :finish)
  end
end
