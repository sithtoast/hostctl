defmodule Hostctl.Backup.Runner do
  @moduledoc """
  GenServer that manages backup execution and scheduling.

  ## Scheduling

  When `schedule_enabled` is true in backup settings, a scheduled backup
  is triggered once per day (or week) at the configured hour and minute.
  The check runs every minute. A backup won't re-trigger if one completed
  successfully within the last hour.

  ## Manual runs

  Call `Hostctl.Backup.Runner.run_now/0` to trigger a backup immediately.
  Returns `:ok` or `{:error, :already_running}`.

  ## PubSub events

  Events are broadcast on the `"backup:events"` topic:
  - `{:backup_started, log_id}`
  - `{:backup_progress, message}`
  - `{:backup_completed, log}`
  - `{:backup_failed, log}`
  """

  use GenServer
  require Logger

  alias Hostctl.Backup
  alias Hostctl.Backup.S3
  alias Hostctl.Repo
  alias Hostctl.Hosting.Domain

  import Ecto.Query

  @schedule_check_interval :timer.minutes(1)
  @pubsub_topic "backup:events"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers a manual backup. Returns :ok or {:error, :already_running}."
  def run_now do
    GenServer.call(__MODULE__, :run_now)
  end

  @doc "Returns the current runner status map."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.send_after(self(), :check_schedule, @schedule_check_interval)
    {:ok, %{running: false, task_ref: nil}}
  end

  @impl true
  def handle_call(:run_now, _from, %{running: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:run_now, _from, state) do
    new_state = start_backup("manual", state)
    {:reply, :ok, new_state}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{running: state.running}, state}
  end

  @impl true
  def handle_info(:check_schedule, state) do
    Process.send_after(self(), :check_schedule, @schedule_check_interval)

    new_state =
      if not state.running do
        settings = Backup.get_or_create_settings()

        if settings.schedule_enabled and should_run_now?(settings) do
          start_backup("scheduled", state)
        else
          state
        end
      else
        state
      end

    {:noreply, new_state}
  end

  # Task completed successfully
  def handle_info({ref, _result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | running: false, task_ref: nil}}
  end

  # Task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.error("[Backup.Runner] Backup task crashed: #{inspect(reason)}")
    broadcast({:backup_failed, nil})
    {:noreply, %{state | running: false, task_ref: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp start_backup(trigger, state) do
    task =
      Task.Supervisor.async_nolink(Hostctl.TaskSupervisor, fn ->
        execute_backup(trigger)
      end)

    %{state | running: true, task_ref: task.ref}
  end

  defp should_run_now?(%{schedule_frequency: freq} = settings) do
    now = DateTime.utc_now()
    time_matches = now.hour == settings.schedule_hour and now.minute == settings.schedule_minute

    day_matches =
      case freq do
        "daily" ->
          true

        "weekly" ->
          Date.day_of_week(DateTime.to_date(now)) == settings.schedule_day_of_week

        _ ->
          false
      end

    if time_matches and day_matches do
      case Backup.get_last_successful_log() do
        nil ->
          true

        log ->
          # Avoid double-triggering within the same 60-minute window
          DateTime.diff(now, log.completed_at, :minute) > 60
      end
    else
      false
    end
  end

  # ---------------------------------------------------------------------------
  # Backup execution (runs in a supervised Task)
  # ---------------------------------------------------------------------------

  def execute_backup(trigger) do
    settings = Backup.get_or_create_settings()

    {:ok, log} =
      Backup.create_log(%{
        trigger: trigger,
        status: "running",
        started_at: DateTime.utc_now()
      })

    broadcast({:backup_started, log.id})

    uid = :erlang.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "hostctl-backup-#{uid}")
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    archive_name = "hostctl-backup-#{timestamp}.tar.gz"
    archive_path = Path.join(System.tmp_dir!(), archive_name)

    File.mkdir_p!(tmp_dir)

    result =
      try do
        if settings.backup_database do
          broadcast_progress("Backing up database…")
          dump_database(tmp_dir)
          broadcast_progress("Database dump complete.")
        end

        if settings.backup_files do
          broadcast_progress("Backing up domain files…")
          backup_domain_files(tmp_dir)
          broadcast_progress("Domain files backup complete.")
        end

        broadcast_progress("Creating archive…")
        create_archive(archive_path, tmp_dir)
        {:ok, %File.Stat{size: file_size}} = File.stat(archive_path)
        broadcast_progress("Archive created (#{format_bytes(file_size)}).")

        local_backup_path =
          if settings.local_enabled do
            broadcast_progress("Storing locally…")
            path = store_local(settings, archive_path, archive_name)
            broadcast_progress("Stored at #{path}.")
            path
          end

        s3_key =
          if settings.s3_enabled do
            broadcast_progress("Uploading to S3…")
            key = upload_to_s3(settings, archive_path, archive_name)
            broadcast_progress("S3 upload complete.")
            key
          end

        destination =
          cond do
            settings.local_enabled and settings.s3_enabled -> "both"
            settings.local_enabled -> "local"
            settings.s3_enabled -> "s3"
            true -> "none"
          end

        if settings.local_enabled, do: apply_local_retention(settings)
        if settings.s3_enabled, do: apply_s3_retention(settings)

        updates = %{
          status: "success",
          completed_at: DateTime.utc_now(),
          file_size_bytes: file_size,
          destination: destination,
          local_path: local_backup_path,
          s3_key: s3_key
        }

        {:ok, updated_log} = Backup.update_log(log, updates)
        broadcast({:backup_completed, updated_log})
        {:ok, updated_log}
      rescue
        e ->
          message = Exception.message(e)
          Logger.error("[Backup.Runner] Backup failed: #{message}")

          {:ok, failed_log} =
            Backup.update_log(log, %{
              status: "failed",
              completed_at: DateTime.utc_now(),
              error_message: message
            })

          broadcast({:backup_failed, failed_log})
          {:error, message}
      end

    File.rm_rf(tmp_dir)
    if File.exists?(archive_path), do: File.rm(archive_path)

    result
  end

  # ---------------------------------------------------------------------------
  # Backup steps
  # ---------------------------------------------------------------------------

  defp dump_database(tmp_dir) do
    config = Hostctl.Repo.config()
    host = to_string(Keyword.get(config, :hostname, "localhost"))
    port = to_string(Keyword.get(config, :port, 5432))
    database = Keyword.get(config, :database)
    username = Keyword.get(config, :username)
    password = to_string(Keyword.get(config, :password) || "")

    dump_file = Path.join(tmp_dir, "database.sql")
    pg_dump = System.find_executable("pg_dump") || "pg_dump"

    args = [
      "--host",
      host,
      "--port",
      port,
      "--username",
      username,
      "--no-password",
      "--format",
      "plain",
      "--file",
      dump_file,
      database
    ]

    case System.cmd(pg_dump, args,
           env: [{"PGPASSWORD", password}],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        raise "pg_dump failed (exit #{code}): #{output}"
    end
  end

  defp backup_domain_files(tmp_dir) do
    domains = Repo.all(from d in Domain, select: [:id, :name, :document_root])
    files_dir = Path.join(tmp_dir, "domains")
    File.mkdir_p!(files_dir)
    tar = System.find_executable("tar") || "tar"

    domains
    |> Enum.filter(fn d -> d.document_root && File.dir?(d.document_root) end)
    |> Enum.each(fn domain ->
      archive = Path.join(files_dir, "#{domain.name}.tar.gz")
      System.cmd(tar, ["-czf", archive, "-C", domain.document_root, "."], stderr_to_stdout: true)
    end)
  end

  defp create_archive(archive_path, source_dir) do
    tar = System.find_executable("tar") || "tar"

    case System.cmd(tar, ["-czf", archive_path, "-C", source_dir, "."], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        raise "tar archive creation failed (exit #{code}): #{output}"
    end
  end

  defp store_local(settings, archive_path, archive_name) do
    local_dir = settings.local_path || "/var/backups/hostctl"
    File.mkdir_p!(local_dir)
    dest = Path.join(local_dir, archive_name)
    File.cp!(archive_path, dest)
    dest
  end

  defp upload_to_s3(settings, archive_path, archive_name) do
    prefix = settings.s3_path_prefix || "hostctl-backups"
    s3_key = "#{prefix}/#{archive_name}"

    case S3.upload(settings, archive_path, s3_key) do
      {:ok, key} -> key
      {:error, reason} -> raise "S3 upload failed: #{reason}"
    end
  end

  defp apply_local_retention(settings) do
    local_dir = settings.local_path || "/var/backups/hostctl"
    retention_secs = (settings.local_retention_days || 7) * 86_400
    cutoff = DateTime.add(DateTime.utc_now(), -retention_secs, :second)

    case File.ls(local_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "hostctl-backup-"))
        |> Enum.each(fn file ->
          path = Path.join(local_dir, file)

          case File.stat(path, time: :posix) do
            {:ok, %File.Stat{mtime: mtime_posix}} ->
              file_dt = DateTime.from_unix!(mtime_posix)

              if DateTime.compare(file_dt, cutoff) == :lt do
                File.rm(path)
                Logger.info("[Backup.Runner] Deleted expired local backup: #{path}")
              end

            _ ->
              :ok
          end
        end)

      {:error, _} ->
        :ok
    end
  end

  defp apply_s3_retention(settings) do
    prefix = settings.s3_path_prefix || "hostctl-backups"
    retention_secs = (settings.s3_retention_days || 30) * 86_400
    cutoff = DateTime.add(DateTime.utc_now(), -retention_secs, :second)

    case S3.list_objects(settings, prefix <> "/") do
      {:ok, objects} ->
        objects
        |> Enum.filter(fn %{last_modified: lm} ->
          case DateTime.from_iso8601(lm) do
            {:ok, dt, _} -> DateTime.compare(dt, cutoff) == :lt
            _ -> false
          end
        end)
        |> Enum.each(fn %{key: key} ->
          case S3.delete_object(settings, key) do
            :ok ->
              Logger.info("[Backup.Runner] Deleted expired S3 object: #{key}")

            {:error, reason} ->
              Logger.warning("[Backup.Runner] Failed to delete S3 object #{key}: #{reason}")
          end
        end)

      {:error, reason} ->
        Logger.warning("[Backup.Runner] Could not list S3 objects for retention: #{reason}")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Hostctl.PubSub, @pubsub_topic, event)
  end

  defp broadcast_progress(message) do
    broadcast({:backup_progress, message})
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} B"
end
