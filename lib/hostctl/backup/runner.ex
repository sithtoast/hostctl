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
  alias Hostctl.Hosting.{Domain, Subdomain, Database}

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

    # When S3-only streaming mode is selected, stream each piece directly to S3
    # without any local temp files, keeping peak disk usage near zero.
    if settings.s3_enabled and settings.s3_mode == "stream" do
      execute_stream_backup(log, settings)
    else
      execute_archive_backup(log, settings)
    end
  end

  # S3-only path: stream database and domain files directly to S3 via multipart
  # upload. No tmp files are created; data flows through memory in chunks.
  defp execute_stream_backup(log, settings) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    prefix = "#{settings.s3_path_prefix || "hostctl-backups"}/hostctl-backup-#{timestamp}"
    tar = System.find_executable("tar") || "tar"

    result =
      try do
        if settings.backup_database do
          broadcast_progress("Streaming database to S3…")
          stream_database_to_s3(settings, "#{prefix}/database.sql.gz")
          broadcast_progress("Database backup complete.")
        end

        if settings.backup_mysql do
          broadcast_progress("Streaming MySQL databases to S3…")
          stream_mysql_databases_to_s3(settings, prefix)
          broadcast_progress("MySQL backup complete.")
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
          s3_key: prefix
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

    File.mkdir_p!(tmp_dir)

    result =
      try do
        if settings.backup_database do
          broadcast_progress("Backing up database…")
          dump_database(tmp_dir)
          broadcast_progress("Database dump complete.")
        end

        if settings.backup_mysql do
          broadcast_progress("Backing up MySQL databases…")
          dump_mysql_databases(tmp_dir)
          broadcast_progress("MySQL dump complete.")
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

  # Dumps each hosted MySQL database to `tmp_dir/mysql/<name>.sql` using
  # mysqldump. Skips if no MySQL databases exist.
  defp dump_mysql_databases(tmp_dir) do
    databases = mysql_databases()
    if databases == [], do: :ok

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
  end

  @mail_base "/var/mail/vhosts"

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
          select: {d.id, d.name, d.document_root, ds.s3_mode}
      )

    files_dir = Path.join(tmp_dir, "domains")
    File.mkdir_p!(files_dir)

    Enum.each(domains, fn {_id, name, doc_root, per_mode} ->
      effective_mode = per_mode || settings.s3_mode || "archive"

      cond do
        is_nil(doc_root) or not File.dir?(doc_root) ->
          :skip

        effective_mode == "stream" and settings.s3_enabled ->
          prefix = "#{settings.s3_path_prefix || "hostctl-backups"}/domains"
          s3_key = "#{prefix}/#{name}.tar.gz"
          broadcast_progress("  → Streaming #{name} to S3…")
          stream = command_to_stream(tar, ["-czf", "-", "-C", doc_root, "."])

          case S3.upload_stream(settings, s3_key, stream) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "S3 stream upload failed for #{name}: #{reason}"
          end

        true ->
          archive = Path.join(files_dir, "#{name}.tar.gz")
          System.cmd(tar, ["-czf", archive, "-C", doc_root, "."], stderr_to_stdout: true)
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
            s3_mode: ss.s3_mode
          }
      )

    Enum.each(subdomains, fn sub ->
      effective_mode = sub.s3_mode || settings.s3_mode || "archive"
      filename = "#{sub.name}.#{sub.domain_name}.tar.gz"

      cond do
        is_nil(sub.document_root) or not File.dir?(sub.document_root) ->
          :skip

        effective_mode == "stream" and settings.s3_enabled ->
          prefix = "#{settings.s3_path_prefix || "hostctl-backups"}/domains"
          s3_key = "#{prefix}/#{filename}"
          broadcast_progress("  → Streaming #{filename} to S3…")
          stream = command_to_stream(tar, ["-czf", "-", "-C", sub.document_root, "."])

          case S3.upload_stream(settings, s3_key, stream) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "S3 stream upload failed for #{filename}: #{reason}"
          end

        true ->
          archive = Path.join(files_dir, filename)
          System.cmd(tar, ["-czf", archive, "-C", sub.document_root, "."], stderr_to_stdout: true)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # S3 streaming helpers (zero extra disk usage)
  # ---------------------------------------------------------------------------

  # Runs mysqldump for each hosted MySQL database, gzip-compresses the output
  # in memory, and uploads each to S3 as `<prefix>/mysql/<name>.sql.gz`.
  defp stream_mysql_databases_to_s3(settings, prefix) do
    databases = mysql_databases()
    if databases == [], do: :ok

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
          select: {d.name, d.document_root, ds.s3_mode}
      )

    subdomains =
      Repo.all(
        from s in Subdomain,
          join: d in Domain,
          on: d.id == s.domain_id,
          left_join: ss in Hostctl.Backup.SubdomainSetting,
          on: ss.subdomain_id == s.id,
          where: s.id not in ^excluded_sub_ids,
          select: {s.name, d.name, s.document_root, ss.s3_mode}
      )

    entries =
      Enum.map(domains, fn {name, doc_root, mode} -> {"#{name}.tar.gz", doc_root, mode} end) ++
        Enum.map(subdomains, fn {sname, dname, doc_root, mode} ->
          {"#{sname}.#{dname}.tar.gz", doc_root, mode}
        end)

    entries
    |> Enum.filter(fn {_, doc_root, _} -> doc_root && File.dir?(doc_root) end)
    |> Enum.each(fn {filename, doc_root, per_mode} ->
      effective_mode = per_mode || "stream"
      s3_key = "#{prefix}/domains/#{filename}"

      if effective_mode == "archive" do
        # Per-domain override: tar to a tmp file then upload
        tmp = Path.join(System.tmp_dir!(), "hostctl-override-#{filename}")

        try do
          System.cmd(tar, ["-czf", tmp, "-C", doc_root, "."], stderr_to_stdout: true)
          broadcast_progress("  → Uploading #{filename} (archive override)…")

          case S3.upload(settings, tmp, s3_key) do
            {:ok, _} -> :ok
            {:error, reason} -> raise "S3 upload failed for #{filename}: #{reason}"
          end
        after
          File.rm(tmp)
        end
      else
        broadcast_progress("  → Streaming #{filename}…")
        stream = command_to_stream(tar, ["-czf", "-", "-C", doc_root, "."])

        case S3.upload_stream(settings, s3_key, stream) do
          {:ok, _} -> :ok
          {:error, reason} -> raise "S3 stream upload failed for #{filename}: #{reason}"
        end
      end
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
