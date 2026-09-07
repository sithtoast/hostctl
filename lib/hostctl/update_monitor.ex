defmodule Hostctl.UpdateMonitor do
  @moduledoc "A shared, bounded background update check; never installs updates."
  use GenServer
  @interval :timer.hours(6)

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def snapshot do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :snapshot), else: empty()
  end

  def check, do: GenServer.cast(__MODULE__, :check)
  defp empty, do: %{status: :unknown, available?: false, checked_at: nil, last_success_at: nil}

  @impl true
  def init(opts) do
    if Keyword.get(opts, :enabled, true), do: send(self(), :check)

    {:ok,
     %{
       result: empty(),
       task: nil,
       timer: nil,
       deadline: nil,
       checker: Keyword.get(opts, :checker, &Hostctl.Updater.check_for_updates/0),
       interval: Keyword.get(opts, :interval, @interval)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.result, state}
  @impl true
  def handle_cast(:check, state), do: handle_info(:check, state)
  @impl true
  def handle_info(:check, %{task: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    task = Task.Supervisor.async_nolink(Hostctl.TaskSupervisor, state.checker)
    deadline = Process.send_after(self(), {:timeout, task.ref}, 30_000)
    {:noreply, %{state | task: task, deadline: deadline, timer: nil}}
  end

  def handle_info(:check, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %{ref: ref}} = state),
    do: {:noreply, finish(state, {:error, :check_failed})}

  def handle_info({:timeout, ref}, %{task: %{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, finish(state, {:error, :timeout})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp finish(state, response) do
    Process.cancel_timer(state.deadline)
    now = DateTime.utc_now()

    result =
      case response do
        {:ok, %{has_update: available}} ->
          %{
            state.result
            | status: :ok,
              available?: available,
              checked_at: now,
              last_success_at: now
          }

        _ ->
          %{state.result | status: :error, checked_at: now}
      end

    Phoenix.PubSub.broadcast(Hostctl.PubSub, "update_status", {:update_status, result})

    %{
      state
      | result: result,
        task: nil,
        deadline: nil,
        timer: Process.send_after(self(), :check, state.interval)
    }
  end
end
