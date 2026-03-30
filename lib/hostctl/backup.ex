defmodule Hostctl.Backup do
  @moduledoc """
  Context for managing backup settings, logs, and triggering backup runs.
  """

  import Ecto.Query
  alias Hostctl.Repo
  alias Hostctl.Backup.{Setting, Log}

  # ---------------------------------------------------------------------------
  # Settings
  # ---------------------------------------------------------------------------

  @doc "Returns the single backup settings row, creating it if it doesn't exist."
  def get_or_create_settings do
    case Repo.one(Setting) do
      nil -> Repo.insert!(%Setting{})
      setting -> setting
    end
  end

  @doc "Returns a changeset for the backup settings."
  def change_settings(%Setting{} = setting, attrs \\ %{}) do
    Setting.changeset(setting, attrs)
  end

  @doc "Saves updated backup settings."
  def update_settings(%Setting{} = setting, attrs) do
    setting
    |> Setting.changeset(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Logs
  # ---------------------------------------------------------------------------

  @doc "Lists recent backup logs, newest first."
  def list_logs(limit \\ 25) do
    Log
    |> order_by([l], desc: l.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Creates a backup log entry."
  def create_log(attrs) do
    %Log{}
    |> Log.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates an existing backup log entry."
  def update_log(%Log{} = log, attrs) do
    log
    |> Log.changeset(attrs)
    |> Repo.update()
  end

  @doc "Returns the most recent successful backup log, or nil."
  def get_last_successful_log do
    Log
    |> where([l], l.status == "success")
    |> order_by([l], desc: l.completed_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Returns true if a backup is currently marked as running."
  def backup_running? do
    Repo.exists?(from l in Log, where: l.status == "running")
  end
end
