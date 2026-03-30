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

  Call `Hostctl.Backup.Runner.cancel/0` to cancel the currently running backup.
  Returns `:ok` or `{:error, :not_running}`.

  ## PubSub events

  Events are broadcast on the `"backup:events"` topic:
  - `{:backup_started, log_id}`
  - `{:backup_progress, message}`
  - `{:backup_completed, log}`
  - `{:backup_cancelled, log}`
  - `{:backup_failed, log}`
  """

  use GenServer
  require Logger

  alias Hostctl.Backup
  alias Hostctl.Backup.Archive
  alias Hostctl.Backup.S3
  alias Hostctl.Repo
  alias Hostctl.Backup.{DomainSetting, SubdomainSetting}
  alias Hostctl.Hosting.{Domain, Subdomain, Database}

  import Ecto.Query

  @schedule_check_interval :timer.minutes(1)
  @pubsub_topic "backup:events"
  @mail_base "/var/mail/vhosts"

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

  @doc "Triggers a one-off backup for a specific domain id."
  def run_domain_now(domain_id) when is_integer(domain_id) do
    GenServer.call(__MODULE__, {:run_domain_now, domain_id})
  end

  @doc "Cancels the currently running backup task."
  def cancel do
    GenServer.call(__MODULE__, :cancel)
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

    {:ok,
     %{running: false, task_ref: nil, task_pid: nil, current_log_id: nil, cancel_requested: false}}
  end

  @impl true
  def handle_call(:run_now, _from, %{running: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call(:run_now, _from, state) do
    case start_backup("manual", state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:run_domain_now, _domain_id}, _from, %{running: true} = state) do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({:run_domain_now, domain_id}, _from, state) do
    case Repo.get(Domain, domain_id) do
      %Domain{} = domain ->
        case start_domain_backup(domain, state) do
          {:ok, new_state} -> {:reply, :ok, new_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:cancel, _from, %{running: false} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:cancel, _from, %{task_pid: task_pid} = state) do
    if is_pid(task_pid) do
      Process.exit(task_pid, :kill)
    end

    {:reply, :ok, %{state | cancel_requested: true}}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{running: state.running, cancel_requested: state.cancel_requested}, state}
  end

  @impl true
  def handle_info(:check_schedule, state) do
    Process.send_after(self(), :check_schedule, @schedule_check_interval)

    new_state =
      if not state.running do
        settings = Backup.get_or_create_settings()

        if settings.schedule_enabled and should_run_now?(settings) do
          case start_backup("scheduled", state) do
            {:ok, new_state} -> new_state
            {:error, _reason} -> state
          end
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
    {:noreply, clear_task_state(state)}
  end

  # Task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    next_state = clear_task_state(state)

    cond do
      state.cancel_requested or reason == :killed ->
        maybe_mark_cancelled(state.current_log_id)
        {:noreply, next_state}

      true ->
        Logger.error("[Backup.Runner] Backup task crashed: #{inspect(reason)}")
        broadcast({:backup_failed, nil})
        {:noreply, next_state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp start_backup(trigger, state) do
    settings = Backup.get_or_create_settings()

    with {:ok, log} <-
           Backup.create_log(%{
             trigger: trigger,
             status: "running",
             started_at: DateTime.utc_now()
           }) do
      task =
        Task.Supervisor.async_nolink(Hostctl.TaskSupervisor, fn ->
          execute_backup(log, settings)
        end)

      broadcast({:backup_started, log.id})

      {:ok,
       %{
         state
         | running: true,
           task_ref: task.ref,
           task_pid: task.pid,
           current_log_id: log.id,
           cancel_requested: false
       }}
    end
  end

  defp start_domain_backup(%Domain{} = domain, state) do
    settings = Backup.get_or_create_settings()

    with {:ok, log} <-
           Backup.create_log(%{
             trigger: "manual_domain",
             status: "running",
             started_at: DateTime.utc_now()
           }) do
      task =
        Task.Supervisor.async_nolink(Hostctl.TaskSupervisor, fn ->
          execute_domain_backup(log, settings, domain)
        end)

      broadcast({:backup_started, log.id})

      {:ok,
       %{
         state
         | running: true,
           task_ref: task.ref,
           task_pid: task.pid,
           current_log_id: log.id,
           cancel_requested: false
       }}
    end
  end

  defp clear_task_state(state) do
    %{
      state
      | running: false,
        task_ref: nil,
        task_pid: nil,
        current_log_id: nil,
        cancel_requested: false
    }
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

  def execute_backup(log, settings) do
    # When S3-only streaming mode is selected, stream each piece directly to S3
    # without any local temp files, keeping peak disk usage near zero.
    if settings.s3_enabled and settings.s3_mode == "stream" do
      execute_stream_backup(log, settings)
    else
      execute_archive_backup(log, settings)
    end
  end

  def execute_domain_backup(log, settings, domain) do
    if settings.s3_enabled and settings.s3_mode == "stream" do
      execute_stream_domain_backup(log, settings, domain)
    else
      execute_archive_domain_backup(log, settings, domain)
    end
  end

  defp maybe_mark_cancelled(nil), do: :ok

  defp maybe_mark_cancelled(log_id) do
    case Backup.get_log(log_id) do
      %Hostctl.Backup.Log{status: "running"} = log ->
        {:ok, cancelled_log} =
          Backup.update_log(log, %{
            status: "cancelled",
            completed_at: DateTime.utc_now(),
            error_message: "Backup cancelled by user."
          })

        broadcast({:backup_cancelled, cancelled_log})
        :ok

      _ ->
        :ok
    end
  end

  # S3-only path: stream database and domain files directly to S3 via multipart
  # upload. No tmp files are created; data flows through memory in chunks.
  defp execute_stream_backup(log, settings) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    prefix = "#{settings.s3_path_prefix || "hostctl-backups"}/hostctl-backup-#{timestamp}"
    tar = System.find_executable("tar") || "tar"
    details = build_backup_details(settings)

    result =
      try do
        if settings.backup_database do
          broadcast_progress("Streaming panel database to S3…")
          stream_database_to_s3(settings, "#{prefix}/database.sql.gz")
          broadcast_progress("Panel database backup complete.")
        end

        if settings.backup_mysql do
          broadcast_progress("Streaming MySQL databases to S3…")
          stream_user_databases_to_s3(settings, prefix)
          broadcast_progress("User database backup complete.")
        end

        if settings.backup_files do
          broadcast_progress("Streaming domain files to S3…")
          stream_domains_to_s3(settings, prefix, tar)
          broadcast_progress("Domain file streaming complete.")
        end

        if settings.backup_mail do
          broadcast_progress("Streaming mailboxes to S3…")
          stream_mail_to_s3(settings, prefix, tar)
          broadcast_progress("Mailbox streaming complete.")
        end

        apply_s3_retention(settings)

        updates = %{
          status: "success",
          completed_at: DateTime.utc_now(),
          destination: "s3",
          s3_key: prefix,
          details: Map.put(details, :mode, "stream")
        }

        {:ok, updated_log} = Backup.update_log(log, updates)
        broadcast({:backup_completed, updated_log})
        {:ok, updated_log}
      rescue
        e ->
          message = Exception.message(e)
          Logger.error("[Backup.Runner] Stream backup failed: #{message}")

          {:ok, failed_log} =
            Backup.update_log(log, %{
              status: "failed",
              completed_at: DateTime.utc_now(),
              error_message: message
            })

          broadcast({:backup_failed, failed_log})
          {:error, message}
      end

    result
  end

  # Local (or local+S3) path: build a tmp dir, combine into a single archive,
  # store locally and/or upload to S3. Needs temporary disk space equal to the
  # compressed archive size.
  defp execute_archive_backup(log, settings) do
    uid = :erlang.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "hostctl-backup-#{uid}")
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    archive_name = "hostctl-backup-#{timestamp}.tar.gz"
    archive_path = Path.join(System.tmp_dir!(), archive_name)
    details = build_backup_details(settings)

    File.mkdir_p!(tmp_dir)

    result =
      try do
        if settings.backup_database do
          broadcast_progress("Backing up panel database…")
          dump_database(tmp_dir)
          broadcast_progress("Panel database dump complete.")
        end

        if settings.backup_mysql do
          broadcast_progress("Backing up MySQL databases…")
          dump_user_databases(tmp_dir)
          broadcast_progress("User database dump complete.")
        end

        if settings.backup_files do
          broadcast_progress("Backing up domain files…")
          backup_domain_files(tmp_dir, settings)
          broadcast_progress("Domain files backup complete.")
        end

        if settings.backup_mail do
          broadcast_progress("Backing up mailboxes…")
          backup_mail(tmp_dir)
          broadcast_progress("Mailbox backup complete.")
        end

        broadcast_progress("Building archive index…")
        Archive.write_index!(tmp_dir)

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
          s3_key: s3_key,
          details: Map.put(details, :mode, "archive")
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

  defp execute_archive_domain_backup(log, settings, domain) do
    uid = :erlang.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "hostctl-domain-backup-#{uid}")
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    safe_domain = String.replace(domain.name, ~r/[^a-zA-Z0-9._-]/, "_")
    archive_name = "hostctl-domain-#{safe_domain}-backup-#{timestamp}.tar.gz"
    archive_path = Path.join(System.tmp_dir!(), archive_name)
    details = build_domain_backup_details(settings, domain)

    File.mkdir_p!(tmp_dir)

    result =
      try do
        if settings.backup_files do
          broadcast_progress("Backing up domain files for #{domain.name}…")
          backup_domain_scope_files(tmp_dir, domain)
          broadcast_progress("Domain file backup complete.")
        end

        if settings.backup_mail and domain_mail_included?(domain.id) do
          broadcast_progress("Backing up mailboxes for #{domain.name}…")
          backup_domain_mail(tmp_dir, domain.name)
          broadcast_progress("Mailbox backup complete.")
        end

        broadcast_progress("Building archive index…")
        Archive.write_index!(tmp_dir)

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
          s3_key: s3_key,
          details: Map.put(details, :mode, "archive")
        }

        {:ok, updated_log} = Backup.update_log(log, updates)
        broadcast({:backup_completed, updated_log})
        {:ok, updated_log}
      rescue
        e ->
          message = Exception.message(e)
          Logger.error("[Backup.Runner] Domain backup failed: #{message}")

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

  defp execute_stream_domain_backup(log, settings, domain) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    safe_domain = String.replace(domain.name, ~r/[^a-zA-Z0-9._-]/, "_")

    prefix =
      "#{settings.s3_path_prefix || "hostctl-backups"}/hostctl-domain-backup-#{safe_domain}-#{timestamp}"

    tar = System.find_executable("tar") || "tar"
    details = build_domain_backup_details(settings, domain)

    result =
      try do
        if settings.backup_files do
          broadcast_progress("Streaming domain files for #{domain.name} to S3…")
          stream_domain_scope_files_to_s3(settings, prefix, tar, domain)
          broadcast_progress("Domain file streaming complete.")
        end

        if settings.backup_mail and domain_mail_included?(domain.id) do
          broadcast_progress("Streaming mailboxes for #{domain.name} to S3…")
          stream_domain_mail_to_s3(settings, prefix, tar, domain.name)
          broadcast_progress("Mailbox streaming complete.")
        end

        apply_s3_retention(settings)

        updates = %{
          status: "success",
          completed_at: DateTime.utc_now(),
          destination: "s3",
          s3_key: prefix,
          details: Map.put(details, :mode, "stream")
        }

        {:ok, updated_log} = Backup.update_log(log, updates)
        broadcast({:backup_completed, updated_log})
        {:ok, updated_log}
      rescue
        e ->
          message = Exception.message(e)
          Logger.error("[Backup.Runner] Domain stream backup failed: #{message}")

          {:ok, failed_log} =
            Backup.update_log(log, %{
              status: "failed",
              completed_at: DateTime.utc_now(),
              error_message: message
            })

          broadcast({:backup_failed, failed_log})
          {:error, message}
      end

    result
  end

  # ---------------------------------------------------------------------------
  # Backup steps
  # ---------------------------------------------------------------------------

  defp domain_mail_included?(domain_id) do
    case Repo.get_by(DomainSetting, domain_id: domain_id) do
      nil -> true
      %DomainSetting{include_mail: include_mail} -> include_mail
    end
  end

  defp build_backup_details(settings) do
    included_domain_ids = Backup.file_backup_domain_ids()

    domain_names =
      Repo.all(
        from d in Domain,
          where: d.id in ^included_domain_ids,
          order_by: [asc: d.name],
          select: d.name
      )

    excluded_sub_ids = Backup.file_backup_excluded_subdomain_ids()

    subdomain_names =
      Repo.all(
        from s in Subdomain,
          join: d in Domain,
          on: d.id == s.domain_id,
          where: s.id not in ^excluded_sub_ids,
          order_by: [asc: d.name, asc: s.name],
          select: {s.name, d.name}
      )
      |> Enum.map(fn {subdomain_name, domain_name} -> "#{subdomain_name}.#{domain_name}" end)

    mysql_db_names = mysql_databases()
    postgresql_db_names = user_postgresql_databases()

    %{
      scope: "all",
      includes: %{
        database: settings.backup_database,
        mysql: settings.backup_mysql,
        files: settings.backup_files,
        mail: settings.backup_mail
      },
      domain_names: domain_names,
      subdomain_names: subdomain_names,
      mail_domain_names: Backup.mail_backup_domain_names(),
      mysql_databases: mysql_db_names,
      postgresql_databases: postgresql_db_names
    }
  end

  defp build_domain_backup_details(settings, %Domain{} = domain) do
    subdomain_names =
      Repo.all(
        from s in Subdomain,
          where: s.domain_id == ^domain.id,
          order_by: [asc: s.name],
          select: s.name
      )
      |> Enum.map(fn subdomain_name -> "#{subdomain_name}.#{domain.name}" end)

    %{
      scope: "domain",
      includes: %{
        database: false,
        mysql: false,
        files: settings.backup_files,
        mail: settings.backup_mail and domain_mail_included?(domain.id)
      },
      domain_names: [domain.name],
      subdomain_names: subdomain_names,
      mail_domain_names: if(domain_mail_included?(domain.id), do: [domain.name], else: []),
      mysql_databases: [],
      postgresql_databases: []
    }
  end

  defp backup_domain_scope_files(tmp_dir, %Domain{} = domain) do
    tar = System.find_executable("tar") || "tar"
    files_dir = Path.join(tmp_dir, "domains")
    File.mkdir_p!(files_dir)

    {include_domain_files, domain_excluded_dirs} =
      case Repo.get_by(DomainSetting, domain_id: domain.id) do
        nil ->
          {true, []}

        %DomainSetting{include_files: include_files, excluded_dirs: excluded_dirs} ->
          {include_files, excluded_dirs || []}
      end

    if (include_domain_files and domain.document_root) && File.dir?(domain.document_root) do
      archive = Path.join(files_dir, "#{domain.name}.tar.gz")

      System.cmd(
        tar,
        tar_args_with_excludes(archive, domain.document_root, domain_excluded_dirs),
        stderr_to_stdout: true
      )
    end

    subdomains =
      Repo.all(
        from s in Subdomain,
          left_join: ss in SubdomainSetting,
          on: ss.subdomain_id == s.id,
          where: s.domain_id == ^domain.id,
          select: {s.name, s.document_root, ss.include_files, ss.excluded_dirs}
      )

    Enum.each(subdomains, fn {sub_name, doc_root, include_files, excluded_dirs} ->
      if ((is_nil(include_files) or include_files) and doc_root) && File.dir?(doc_root) do
        archive = Path.join(files_dir, "#{sub_name}.#{domain.name}.tar.gz")

        System.cmd(
          tar,
          tar_args_with_excludes(archive, doc_root, excluded_dirs || []),
          stderr_to_stdout: true
        )
      end
    end)
  end

  defp backup_domain_mail(tmp_dir, domain_name) do
    domain_mail = Path.join(@mail_base, domain_name)

    if File.dir?(domain_mail) do
      tar = System.find_executable("tar") || "tar"
      mail_dir = Path.join(tmp_dir, "mail")
      File.mkdir_p!(mail_dir)
      archive = Path.join(mail_dir, "#{domain_name}.tar.gz")
      System.cmd(tar, ["-czf", archive, "-C", domain_mail, "."], stderr_to_stdout: true)
    end
  end

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

  defp mysql_server_config do
    cfg = Application.get_env(:hostctl, :database_server, [])
    host = to_string(Keyword.get(cfg, :hostname, "localhost"))
    port = to_string(Keyword.get(cfg, :port, 3306))
    username = to_string(Keyword.get(cfg, :username, "root"))
    password = to_string(Keyword.get(cfg, :password, ""))
    {host, port, username, password}
  end

  defp mysql_databases do
    Repo.all(from d in Database, where: d.db_type == "mysql", select: d.name, order_by: d.name)
  end

  defp user_postgresql_databases do
    Repo.all(
      from d in Database,
        where: d.db_type == "postgresql",
        select: d.name,
        order_by: d.name
    )
  end

  defp postgres_server_config do
    config = Hostctl.Repo.config()
    host = to_string(Keyword.get(config, :hostname, "localhost"))
    port = to_string(Keyword.get(config, :port, 5432))
    username = to_string(Keyword.get(config, :username))
    password = to_string(Keyword.get(config, :password) || "")
    {host, port, username, password}
  end

  # Dumps each hosted user database to tmp files:
  #   - MySQL/MariaDB: `tmp_dir/mysql/<name>.sql`
  #   - PostgreSQL: `tmp_dir/postgresql/<name>.sql`
  defp dump_user_databases(tmp_dir) do
    databases = mysql_databases()
    {host, port, username, password} = mysql_server_config()
    mysql_dump = System.find_executable("mysqldump") || "mysqldump"
    mysql_dir = Path.join(tmp_dir, "mysql")
    File.mkdir_p!(mysql_dir)

    Enum.each(databases, fn db_name ->
      dump_file = Path.join(mysql_dir, "#{db_name}.sql")
      broadcast_progress("  → Dumping MySQL database #{db_name}…")

      args = [
        "--host",
        host,
        "--port",
        port,
        "--user",
        username,
        "--single-transaction",
        "--routines",
        "--triggers",
        "--result-file",
        dump_file,
        db_name
      ]

      case System.cmd(mysql_dump, args,
             env: [{"MYSQL_PWD", password}],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        {output, code} ->
          raise "mysqldump failed for #{db_name} (exit #{code}): #{output}"
      end
    end)

    pg_databases = user_postgresql_databases()
    {pg_host, pg_port, pg_user, pg_password} = postgres_server_config()
    pg_dump = System.find_executable("pg_dump") || "pg_dump"
    pg_dir = Path.join(tmp_dir, "postgresql")
    File.mkdir_p!(pg_dir)

    Enum.each(pg_databases, fn db_name ->
      dump_file = Path.join(pg_dir, "#{db_name}.sql")
      broadcast_progress("  → Dumping PostgreSQL database #{db_name}…")

      args = [
        "--host",
        pg_host,
        "--port",
        pg_port,
        "--username",
        pg_user,
        "--no-password",
        "--format",
        "plain",
        "--file",
        dump_file,
        db_name
      ]

      case System.cmd(pg_dump, args,
             env: [{"PGPASSWORD", pg_password}],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        {output, code} ->
          raise "pg_dump failed for #{db_name} (exit #{code}): #{output}"
      end
    end)
  end

  # Archives each included domain's mailboxes to `tmp_dir/mail/<domain>.tar.gz`.
  defp backup_mail(tmp_dir) do
    domain_names = Backup.mail_backup_domain_names()
    tar = System.find_executable("tar") || "tar"
    mail_dir = Path.join(tmp_dir, "mail")
    File.mkdir_p!(mail_dir)

    Enum.each(domain_names, fn domain_name ->
      domain_mail = Path.join(@mail_base, domain_name)

      if File.dir?(domain_mail) do
        archive = Path.join(mail_dir, "#{domain_name}.tar.gz")
        broadcast_progress("  → Archiving mail for #{domain_name}…")
        System.cmd(tar, ["-czf", archive, "-C", domain_mail, "."], stderr_to_stdout: true)
      end
    end)
  end

  defp backup_domain_files(tmp_dir, settings) do
    included_ids = Backup.file_backup_domain_ids()
    tar = System.find_executable("tar") || "tar"

    domains =
      Repo.all(
        from d in Domain,
          left_join: ds in Hostctl.Backup.DomainSetting,
          on: ds.domain_id == d.id,
          where: d.id in ^included_ids,
          select: {d.id, d.name, d.document_root, ds.s3_mode, ds.excluded_dirs}
      )

    files_dir = Path.join(tmp_dir, "domains")
    File.mkdir_p!(files_dir)

    Enum.each(domains, fn {_id, name, doc_root, per_mode, excluded_dirs} ->
      effective_mode = per_mode || settings.s3_mode || "archive"
      excluded_dirs = excluded_dirs || []

      cond do
        is_nil(doc_root) or not File.dir?(doc_root) ->
          :skip

        effective_mode == "stream" and settings.s3_enabled ->
          prefix = "#{settings.s3_path_prefix || "hostctl-backups"}/domains"
          s3_key = "#{prefix}/#{name}.tar.gz"
          broadcast_progress("  → Streaming #{name} to S3…")
          stream = command_to_stream(tar, tar_args_with_excludes("-", doc_root, excluded_dirs))

          case S3.upload_stream(settings, s3_key, stream) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "S3 stream upload failed for #{name}: #{reason}"
          end

        true ->
          archive = Path.join(files_dir, "#{name}.tar.gz")

          System.cmd(
            tar,
            tar_args_with_excludes(archive, doc_root, excluded_dirs),
            stderr_to_stdout: true
          )
      end
    end)

    backup_subdomains(files_dir, settings, tar)
  end

  defp backup_subdomains(files_dir, settings, tar) do
    excluded_ids = Backup.file_backup_excluded_subdomain_ids()

    subdomains =
      Repo.all(
        from s in Subdomain,
          join: d in Domain,
          on: d.id == s.domain_id,
          left_join: ss in Hostctl.Backup.SubdomainSetting,
          on: ss.subdomain_id == s.id,
          where: s.id not in ^excluded_ids,
          select: %{
            name: s.name,
            domain_name: d.name,
            document_root: s.document_root,
            s3_mode: ss.s3_mode,
            excluded_dirs: ss.excluded_dirs
          }
      )

    Enum.each(subdomains, fn sub ->
      effective_mode = sub.s3_mode || settings.s3_mode || "archive"
      filename = "#{sub.name}.#{sub.domain_name}.tar.gz"
      excluded_dirs = sub.excluded_dirs || []

      cond do
        is_nil(sub.document_root) or not File.dir?(sub.document_root) ->
          :skip

        effective_mode == "stream" and settings.s3_enabled ->
          prefix = "#{settings.s3_path_prefix || "hostctl-backups"}/domains"
          s3_key = "#{prefix}/#{filename}"
          broadcast_progress("  → Streaming #{filename} to S3…")

          stream =
            command_to_stream(tar, tar_args_with_excludes("-", sub.document_root, excluded_dirs))

          case S3.upload_stream(settings, s3_key, stream) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "S3 stream upload failed for #{filename}: #{reason}"
          end

        true ->
          archive = Path.join(files_dir, filename)

          System.cmd(
            tar,
            tar_args_with_excludes(archive, sub.document_root, excluded_dirs),
            stderr_to_stdout: true
          )
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # S3 streaming helpers (zero extra disk usage)
  # ---------------------------------------------------------------------------

  defp stream_domain_scope_files_to_s3(settings, prefix, tar, %Domain{} = domain) do
    {include_domain_files, domain_excluded_dirs, domain_s3_mode} =
      case Repo.get_by(DomainSetting, domain_id: domain.id) do
        nil ->
          {true, [], nil}

        %DomainSetting{
          include_files: include_files,
          excluded_dirs: excluded_dirs,
          s3_mode: s3_mode
        } ->
          {include_files, excluded_dirs || [], s3_mode}
      end

    if (include_domain_files and domain.document_root) && File.dir?(domain.document_root) do
      effective_mode = domain_s3_mode || "stream"

      if effective_mode == "raw" do
        upload_directory_raw_to_s3(
          settings,
          "#{prefix}/domains/#{domain.name}",
          domain.document_root,
          domain_excluded_dirs
        )
      else
        s3_key = "#{prefix}/domains/#{domain.name}.tar.gz"

        stream =
          command_to_stream(
            tar,
            tar_args_with_excludes("-", domain.document_root, domain_excluded_dirs)
          )

        case S3.upload_stream(settings, s3_key, stream) do
          {:ok, _} -> :ok
          {:error, reason} -> raise "S3 stream upload failed for #{domain.name}: #{reason}"
        end
      end
    end

    subdomains =
      Repo.all(
        from s in Subdomain,
          left_join: ss in SubdomainSetting,
          on: ss.subdomain_id == s.id,
          where: s.domain_id == ^domain.id,
          select: {s.name, s.document_root, ss.include_files, ss.excluded_dirs, ss.s3_mode}
      )

    Enum.each(subdomains, fn {sub_name, doc_root, include_files, excluded_dirs, s3_mode} ->
      if ((is_nil(include_files) or include_files) and doc_root) && File.dir?(doc_root) do
        base_name = "#{sub_name}.#{domain.name}"
        effective_mode = s3_mode || "stream"

        if effective_mode == "raw" do
          upload_directory_raw_to_s3(
            settings,
            "#{prefix}/domains/#{base_name}",
            doc_root,
            excluded_dirs || []
          )
        else
          filename = "#{base_name}.tar.gz"
          s3_key = "#{prefix}/domains/#{filename}"

          stream =
            command_to_stream(tar, tar_args_with_excludes("-", doc_root, excluded_dirs || []))

          case S3.upload_stream(settings, s3_key, stream) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "S3 stream upload failed for #{filename}: #{reason}"
          end
        end
      end
    end)
  end

  defp stream_domain_mail_to_s3(settings, prefix, tar, domain_name) do
    domain_mail = Path.join(@mail_base, domain_name)

    if File.dir?(domain_mail) do
      s3_key = "#{prefix}/mail/#{domain_name}.tar.gz"
      stream = command_to_stream(tar, ["-czf", "-", "-C", domain_mail, "."])

      case S3.upload_stream(settings, s3_key, stream) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "S3 mail upload failed for #{domain_name}: #{reason}"
      end
    end
  end

  # Streams each hosted user database directly to S3:
  #   - MySQL/MariaDB: `<prefix>/mysql/<name>.sql.gz`
  #   - PostgreSQL: `<prefix>/postgresql/<name>.sql.gz`
  defp stream_user_databases_to_s3(settings, prefix) do
    databases = mysql_databases()
    {host, port, username, password} = mysql_server_config()
    mysql_dump = System.find_executable("mysqldump") || "mysqldump"

    Enum.each(databases, fn db_name ->
      broadcast_progress("  → Streaming MySQL database #{db_name} to S3…")
      s3_key = "#{prefix}/mysql/#{db_name}.sql.gz"

      args = [
        "--host",
        host,
        "--port",
        port,
        "--user",
        username,
        "--single-transaction",
        "--routines",
        "--triggers",
        db_name
      ]

      case System.cmd(mysql_dump, args,
             env: [{"MYSQL_PWD", password}],
             stderr_to_stdout: true
           ) do
        {dump_data, 0} ->
          compressed = :zlib.gzip(dump_data)

          case S3.upload_binary(settings, s3_key, compressed) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "MySQL S3 upload failed for #{db_name}: #{reason}"
          end

        {output, code} ->
          raise "mysqldump failed for #{db_name} (exit #{code}): #{output}"
      end
    end)

    pg_databases = user_postgresql_databases()
    {pg_host, pg_port, pg_user, pg_password} = postgres_server_config()
    pg_dump = System.find_executable("pg_dump") || "pg_dump"

    Enum.each(pg_databases, fn db_name ->
      broadcast_progress("  → Streaming PostgreSQL database #{db_name} to S3…")
      s3_key = "#{prefix}/postgresql/#{db_name}.sql.gz"

      args = [
        "--host",
        pg_host,
        "--port",
        pg_port,
        "--username",
        pg_user,
        "--no-password",
        "--format",
        "plain",
        db_name
      ]

      case System.cmd(pg_dump, args,
             env: [{"PGPASSWORD", pg_password}],
             stderr_to_stdout: true
           ) do
        {dump_data, 0} ->
          compressed = :zlib.gzip(dump_data)

          case S3.upload_binary(settings, s3_key, compressed) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "PostgreSQL S3 upload failed for #{db_name}: #{reason}"
          end

        {output, code} ->
          raise "pg_dump failed for #{db_name} (exit #{code}): #{output}"
      end
    end)
  end

  # Streams each included domain's mailboxes to S3 as `<prefix>/mail/<domain>.tar.gz`.
  defp stream_mail_to_s3(settings, prefix, tar) do
    domain_names = Backup.mail_backup_domain_names()

    Enum.each(domain_names, fn domain_name ->
      domain_mail = Path.join(@mail_base, domain_name)

      if File.dir?(domain_mail) do
        s3_key = "#{prefix}/mail/#{domain_name}.tar.gz"
        broadcast_progress("  → Streaming mail for #{domain_name}…")
        stream = command_to_stream(tar, ["-czf", "-", "-C", domain_mail, "."])

        case S3.upload_stream(settings, s3_key, stream) do
          {:ok, _} -> :ok
          {:error, reason} -> raise "S3 mail upload failed for #{domain_name}: #{reason}"
        end
      end
    end)
  end

  # Runs pg_dump, gzip-compresses the output in memory, and uploads to S3.
  # Avoids writing any temp files. Reasonable for database dumps up to a few GB.
  defp stream_database_to_s3(settings, s3_key) do
    config = Hostctl.Repo.config()
    host = to_string(Keyword.get(config, :hostname, "localhost"))
    port = to_string(Keyword.get(config, :port, 5432))
    database = Keyword.get(config, :database)
    username = Keyword.get(config, :username)
    password = to_string(Keyword.get(config, :password) || "")
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
      database
    ]

    case System.cmd(pg_dump, args, env: [{"PGPASSWORD", password}], stderr_to_stdout: true) do
      {dump_data, 0} ->
        compressed = :zlib.gzip(dump_data)

        case S3.upload_binary(settings, s3_key, compressed) do
          {:ok, _} -> :ok
          {:error, reason} -> raise "Database S3 upload failed: #{reason}"
        end

      {output, code} ->
        raise "pg_dump failed (exit #{code}): #{output}"
    end
  end

  # Streams each domain and subdomain's document root directly to S3 via
  # `tar czf -` piped through a Port. No temp files are written.
  # Entries with a per-domain override of "archive" are collected into a tmp
  # dir instead and included in the combined archive at the end.
  defp stream_domains_to_s3(settings, prefix, tar) do
    included_ids = Backup.file_backup_domain_ids()
    excluded_sub_ids = Backup.file_backup_excluded_subdomain_ids()

    domains =
      Repo.all(
        from d in Domain,
          left_join: ds in Hostctl.Backup.DomainSetting,
          on: ds.domain_id == d.id,
          where: d.id in ^included_ids,
          select: {d.name, d.document_root, ds.s3_mode, ds.excluded_dirs}
      )

    subdomains =
      Repo.all(
        from s in Subdomain,
          join: d in Domain,
          on: d.id == s.domain_id,
          left_join: ss in Hostctl.Backup.SubdomainSetting,
          on: ss.subdomain_id == s.id,
          where: s.id not in ^excluded_sub_ids,
          select: {s.name, d.name, s.document_root, ss.s3_mode, ss.excluded_dirs}
      )

    entries =
      Enum.map(domains, fn {name, doc_root, mode, excluded_dirs} ->
        {name, doc_root, mode, excluded_dirs || []}
      end) ++
        Enum.map(subdomains, fn {sname, dname, doc_root, mode, excluded_dirs} ->
          {"#{sname}.#{dname}", doc_root, mode, excluded_dirs || []}
        end)

    entries
    |> Enum.filter(fn {_, doc_root, _, _} -> doc_root && File.dir?(doc_root) end)
    |> Enum.each(fn {name, doc_root, per_mode, excluded_dirs} ->
      effective_mode = per_mode || "stream"
      archive_name = "#{name}.tar.gz"
      s3_key = "#{prefix}/domains/#{archive_name}"

      if effective_mode == "archive" do
        # Per-domain override: tar to a tmp file then upload
        tmp = Path.join(System.tmp_dir!(), "hostctl-override-#{archive_name}")

        try do
          System.cmd(tar, tar_args_with_excludes(tmp, doc_root, excluded_dirs),
            stderr_to_stdout: true
          )

          broadcast_progress("  → Uploading #{archive_name} (archive override)…")

          case S3.upload(settings, tmp, s3_key) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "S3 upload failed for #{archive_name}: #{reason}"
          end
        after
          File.rm(tmp)
        end
      else
        if effective_mode == "raw" do
          broadcast_progress("  → Uploading raw files for #{name}…")

          upload_directory_raw_to_s3(
            settings,
            "#{prefix}/domains/#{name}",
            doc_root,
            excluded_dirs
          )
        else
          broadcast_progress("  → Streaming #{archive_name}…")
          stream = command_to_stream(tar, tar_args_with_excludes("-", doc_root, excluded_dirs))

          case S3.upload_stream(settings, s3_key, stream) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "S3 stream upload failed for #{archive_name}: #{reason}"
          end
        end
      end
    end)
  end

  defp tar_args_with_excludes(output_path, root_dir, excluded_dirs) do
    ["-czf", output_path]
    |> Kernel.++(tar_exclude_args(excluded_dirs || []))
    |> Kernel.++(["-C", root_dir, "."])
  end

  defp tar_exclude_args(excluded_dirs) do
    excluded_dirs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.trim_leading(&1, "/"))
    |> Enum.reject(&String.contains?(&1, ".."))
    |> Enum.flat_map(fn dir -> ["--exclude", "./#{dir}"] end)
  end

  defp upload_directory_raw_to_s3(settings, key_prefix, root_dir, excluded_dirs) do
    normalized_excludes = normalize_excluded_prefixes(excluded_dirs || [])
    root_path = Path.expand(root_dir)

    list_regular_files(root_path)
    |> Enum.each(fn path ->
      rel_path = Path.relative_to(path, root_path)
      rel_path = String.replace(rel_path, "\\", "/")

      unless excluded_rel_path?(rel_path, normalized_excludes) do
        s3_key = "#{key_prefix}/#{rel_path}"

        case S3.upload(settings, path, s3_key) do
          {:ok, _} -> :ok
          {:error, reason} -> raise "S3 raw upload failed for #{s3_key}: #{reason}"
        end
      end
    end)
  end

  defp list_regular_files(root_path) do
    case File.ls(root_path) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          path = Path.join(root_path, entry)

          cond do
            File.regular?(path) -> [path]
            File.dir?(path) -> list_regular_files(path)
            true -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp normalize_excluded_prefixes(excluded_dirs) do
    excluded_dirs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.trim_leading(&1, "/"))
    |> Enum.map(&String.replace(&1, "\\", "/"))
  end

  defp excluded_rel_path?(rel_path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      rel_path == prefix or String.starts_with?(rel_path, prefix <> "/")
    end)
  end

  # Returns a lazy Stream that opens a Port running `executable args` and
  # yields each chunk of stdout as it arrives.
  defp command_to_stream(executable, args) do
    Stream.resource(
      fn ->
        Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args])
      end,
      fn port ->
        receive do
          {^port, {:data, chunk}} ->
            {[chunk], port}

          {^port, {:exit_status, 0}} ->
            {:halt, port}

          {^port, {:exit_status, code}} ->
            raise "Command exited with code #{code}"
        after
          :timer.minutes(30) ->
            raise "Command timed out after 30 minutes"
        end
      end,
      fn port ->
        try do
          Port.close(port)
        rescue
          _ -> :ok
        end
      end
    )
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
