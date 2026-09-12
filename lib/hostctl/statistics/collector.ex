defmodule Hostctl.Statistics.Collector do
  @moduledoc "Refreshes enabled domain reports hourly, one domain at a time."
  use GenServer
  require Logger
  alias Hostctl.Accounts.{Scope, User}
  alias Hostctl.Statistics

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    Process.send_after(self(), :collect, :timer.minutes(1))
    {:ok, nil}
  end

  def handle_info(:collect, nil) do
    task =
      Task.Supervisor.async_nolink(Hostctl.TaskSupervisor, fn ->
        if Statistics.available?() do
          scope = Scope.for_user(%User{role: "admin"})

          for id <- Statistics.enabled_ids() do
            try do
              case Statistics.refresh(scope, id) do
                {:ok, _} -> :ok
                {:error, reason} -> Logger.warning("[Statistics] Domain #{id}: #{reason}")
              end
            rescue
              Ecto.NoResultsError -> :ok
            end
          end
        end
      end)

    {:noreply, task.ref}
  end

  def handle_info({ref, _result}, ref) do
    Process.demonitor(ref, [:flush])
    Process.send_after(self(), :collect, :timer.hours(1))
    {:noreply, nil}
  end

  def handle_info({:DOWN, ref, :process, _, _}, ref) do
    Process.send_after(self(), :collect, :timer.hours(1))
    {:noreply, nil}
  end
end
