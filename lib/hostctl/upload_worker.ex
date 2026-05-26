defmodule Hostctl.UploadWorker do
  @moduledoc """
  GenServer that handles background S3 uploads with resume capability.
  Each upload job runs in its own supervised process, registered by job ID.
  """
  use GenServer, restart: :transient
  require Logger

  alias Hostctl.Hosting
  alias Hostctl.S3Client
  alias Hostctl.Repo

  @pubsub Hostctl.PubSub
  @registry Hostctl.UploadRegistry

  # Client API

  @doc """
  Starts an upload worker for a given upload job ID.
  """
  def start_link(job_id) when is_integer(job_id) do
    GenServer.start_link(__MODULE__, job_id, name: via(job_id))
  end

  @doc """
  Cancels a running upload job, marking it as paused (resumable).
  Returns :ok whether the process was found or not.
  """
  def cancel(job_id) do
    case Registry.lookup(@registry, job_id) do
      [{pid, _}] ->
        GenServer.cast(pid, :cancel)
        :ok

      [] ->
        # Process already gone — just mark it paused in the DB
        job = Hosting.get_upload_job!(job_id)

        if job.status == "running" do
          Hosting.update_upload_job(job, %{status: "paused"})
        end

        :ok
    end
  end

  defp via(job_id), do: {:via, Registry, {@registry, job_id}}

  @doc """
  Starts an upload job and returns the job ID.
  """
  def start_upload(attrs) do
    with {:ok, job} <- Hosting.create_upload_job(attrs) do
      # Start worker via DynamicSupervisor
      case DynamicSupervisor.start_child(
             Hostctl.UploadSupervisor,
             {__MODULE__, job.id}
           ) do
        {:ok, _pid} -> {:ok, job}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Resumes a paused or failed upload job.
  """
  def resume_upload(job_id) do
    job = Hosting.get_upload_job!(job_id)

    if job.status in ["paused", "failed", "pending"] do
      Hosting.update_upload_job(job, %{status: "pending", error_message: nil})

      case DynamicSupervisor.start_child(
             Hostctl.UploadSupervisor,
             {__MODULE__, job.id}
           ) do
        {:ok, _pid} -> {:ok, job}
        {:error, {:already_started, _pid}} -> {:ok, job}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_status}
    end
  end

  # Server callbacks

  @impl true
  def init(job_id) do
    # Start upload immediately
    send(self(), :start_upload)
    {:ok, %{job_id: job_id, cancelled: false}}
  end

  @impl true
  def handle_cast(:cancel, %{job_id: job_id} = state) do
    # Set flag so the upload loop halts between files
    Process.put(:cancel_upload, true)
    Logger.info("[UploadWorker] Job #{job_id} cancellation requested")
    {:noreply, %{state | cancelled: true}}
  end

  @impl true
  def handle_info(:start_upload, %{job_id: job_id} = state) do
    job = Hosting.get_upload_job!(job_id)

    # Update status to running
    {:ok, job} =
      Hosting.update_upload_job(job, %{status: "running", started_at: DateTime.utc_now()})

    broadcast_progress(job)

    result =
      if streaming_mode?(job) do
        run_streaming_upload(job)
      else
        run_staged_upload(job)
      end

    total = job.total_files

    case result do
      {:ok, uploaded_count} ->
        {:ok, _job} =
          Hosting.update_upload_job(job, %{
            status: "completed",
            uploaded_files: uploaded_count,
            completed_at: DateTime.utc_now(),
            current_file: nil
          })

        Logger.info(
          "[UploadWorker] Job #{job_id} completed: #{uploaded_count}/#{total} files uploaded"
        )

        broadcast_progress(Repo.reload!(job))
        {:stop, :normal, state}

      {:paused, uploaded_count} ->
        {:ok, _job} =
          Hosting.update_upload_job(job, %{
            status: "paused",
            uploaded_files: uploaded_count,
            current_file: nil
          })

        Logger.info("[UploadWorker] Job #{job_id} paused at #{uploaded_count}/#{total} files")
        broadcast_progress(Repo.reload!(job))
        {:stop, :normal, state}

      {:error, reason, uploaded_count, failed_count} ->
        {:ok, _job} =
          Hosting.update_upload_job(job, %{
            status: "failed",
            uploaded_files: uploaded_count,
            failed_files: failed_count,
            completed_at: DateTime.utc_now(),
            error_message: inspect(reason),
            current_file: nil
          })

        Logger.error("[UploadWorker] Job #{job_id} failed: #{inspect(reason)}")
        broadcast_progress(Repo.reload!(job))
        {:stop, :normal, state}
    end
  end

  # Private helpers

  # ---------------------------------------------------------------------------
  # Upload modes
  # ---------------------------------------------------------------------------

  # Streaming mode: the worker rsyncs files from the remote server in small
  # batches, uploads each batch to S3, then deletes the local copies before
  # fetching the next batch. This keeps local disk usage bounded to
  # ~(batch_size × avg_file_size) regardless of total site size.
  @batch_size 300

  defp streaming_mode?(job) do
    is_binary(job.remote_source_path) and job.remote_source_path != "" and
      is_binary(job.ssh_host) and job.ssh_host != ""
  end

  defp run_streaming_upload(job) do
    Logger.info("[UploadWorker] Job #{job.id}: streaming mode (batched rsync → S3)")

    # Signal listing phase so the UI shows activity
    {:ok, job} =
      Hosting.update_upload_job(job, %{current_file: "Listing remote files…"})

    broadcast_progress(job)

    # 1. List all files on the remote server via SSH find
    case list_remote_files(job) do
      {:error, reason} ->
        {:error, reason, 0, 0}

      {:ok, all_relative_paths} ->
        total = length(all_relative_paths)

        # 2. Skip files already in S3 (resume support)
        existing_keys = get_existing_s3_keys(job)

        paths_to_upload =
          Enum.reject(all_relative_paths, fn rel ->
            MapSet.member?(existing_keys, s3_key(job, rel))
          end)

        already_done = total - length(paths_to_upload)

        Logger.info(
          "[UploadWorker] Job #{job.id}: #{total} remote files, #{already_done} already in S3, #{length(paths_to_upload)} to upload"
        )

        {:ok, job} =
          Hosting.update_upload_job(job, %{total_files: total, uploaded_files: already_done})

        broadcast_progress(job)

        # 3. Process in batches
        run_batches(job, paths_to_upload, already_done)
    end
  end

  # Traditional mode: files are already staged locally in job.source_path.
  defp run_staged_upload(job) do
    Logger.info("[UploadWorker] Job #{job.id}: staged mode (files already local)")

    existing_keys = get_existing_s3_keys(job)

    all_files =
      job.source_path
      |> list_files_recursive()
      |> Enum.sort()

    files_to_upload =
      Enum.reject(all_files, fn file_path ->
        relative = Path.relative_to(file_path, job.source_path)
        MapSet.member?(existing_keys, s3_key(job, relative))
      end)

    total = length(all_files)
    already_uploaded = total - length(files_to_upload)

    Logger.info(
      "[UploadWorker] Job #{job.id}: #{total} total files, #{already_uploaded} already uploaded"
    )

    {:ok, job} =
      Hosting.update_upload_job(job, %{total_files: total, uploaded_files: already_uploaded})

    result = upload_files(job, files_to_upload, already_uploaded, self())

    # Clean up source directory when done
    if get_in(job.metadata, ["cleanup_source"]) do
      File.rm_rf(job.source_path)
      Logger.debug("[UploadWorker] Cleaned up staged source: #{job.source_path}")
    end

    result
  end

  # ---------------------------------------------------------------------------
  # Batched rsync streaming helpers
  # ---------------------------------------------------------------------------

  defp run_batches(job, paths, done_count) do
    staging_base =
      System.tmp_dir!()
      |> Path.join("hostctl_batch_#{job.id}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(staging_base)

    batches = Enum.chunk_every(paths, @batch_size)
    total_batches = length(batches)

    result =
      batches
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, done_count, 0}, fn {batch_paths, batch_n},
                                                    {:ok, uploaded, failed} ->
        if Process.get(:cancel_upload, false) do
          {:halt, {:paused, uploaded}}
        else
          batch_dir =
            Path.join(staging_base, "b#{System.unique_integer([:positive])}")

          File.mkdir_p!(batch_dir)

          # Show rsync progress in the UI
          {:ok, progress_job} =
            Hosting.update_upload_job(job, %{
              current_file: "Syncing batch #{batch_n}/#{total_batches}…"
            })

          broadcast_progress(progress_job)

          batch_result = process_one_batch(job, batch_paths, batch_dir, uploaded)
          File.rm_rf(batch_dir)

          case batch_result do
            {:ok, new_count} ->
              {:cont, {:ok, new_count, failed}}

            {:paused, new_count} ->
              {:halt, {:paused, new_count}}

            {:error, _errors, new_count, new_failed} ->
              # Continue with remaining batches even if this one had failures
              {:cont, {:ok, new_count, failed + new_failed}}
          end
        end
      end)

    File.rm_rf(staging_base)

    case result do
      {:ok, count, 0} -> {:ok, count}
      {:ok, count, failed} -> {:error, ["#{failed} files failed to upload"], count, failed}
      other -> other
    end
  end

  defp process_one_batch(job, relative_paths, batch_dir, done_count) do
    case rsync_batch(job, relative_paths, batch_dir) do
      :ok ->
        # Only upload files that actually arrived (rsync may skip some)
        local_files =
          relative_paths
          |> Enum.map(&Path.join(batch_dir, &1))
          |> Enum.filter(&File.exists?/1)

        upload_files(%{job | source_path: batch_dir}, local_files, done_count, self())

      {:error, reason} ->
        {:error, ["rsync batch failed: #{reason}"], done_count, length(relative_paths)}
    end
  end

  # Rsyncs a specific list of relative file paths from the remote source.
  defp rsync_batch(job, relative_paths, local_dir) do
    # Write the file list to a temp file for --files-from
    list_file = Path.join(local_dir, ".rsync_files_list")

    File.write!(list_file, Enum.join(relative_paths, "\n"))

    remote_path =
      if String.ends_with?(job.remote_source_path, "/"),
        do: job.remote_source_path,
        else: job.remote_source_path <> "/"

    remote = "#{job.ssh_username}@#{job.ssh_host}:#{remote_path}"
    port = job.ssh_port || "22"

    with {:ok, sshpass_prefix, auth_args, env} <- ssh_auth_parts_from_job(job) do
      ssh_cmd = String.trim("#{sshpass_prefix} ssh #{Enum.join(["-p", port] ++ auth_args, " ")}")
      rsync = System.find_executable("rsync") || "rsync"
      rsync_path = remote_rsync_path_from_job(job)

      # Run rsync directly as the hostctl user — no sudo/systemd-run wrapper.
      # The staging dir lives in hostctl's private /tmp namespace (PrivateTmp=yes
      # in the systemd unit). sudo systemd-run would create a new transient unit
      # in a different /tmp namespace where the --files-from list file doesn't
      # exist. Local rsync needs no root privileges; only the remote side needs
      # sudo (handled by --rsync-path).
      args = [
        "-rltzD",
        "--chmod=D755,F644",
        "--timeout=120",
        "--rsync-path=#{rsync_path}",
        "--files-from=#{list_file}",
        "--relative",
        "-e",
        ssh_cmd,
        remote,
        local_dir <> "/"
      ]

      case System.cmd(rsync, args, stderr_to_stdout: true, env: env) do
        {_, code} when code in [0, 24] ->
          File.rm(list_file)
          :ok

        {output, code} ->
          File.rm(list_file)

          Logger.warning(
            "[UploadWorker] Job #{job.id} rsync_batch failed (exit #{code}) " <>
              "src=#{remote} dst=#{local_dir} files=#{length(relative_paths)}\n" <>
              String.slice(output, 0, 800)
          )

          {:error, "exit #{code}: #{String.slice(output, 0, 300)}"}
      end
    end
  end

  # Lists all regular files under `job.remote_source_path` via SSH, returning
  # relative paths (relative to the remote source directory).
  defp list_remote_files(job) do
    port = job.ssh_port || "22"

    # Escape the remote path for shell use
    remote_path = job.remote_source_path |> String.replace("'", "'\\''")

    # For password auth we need a SUDO_ASKPASS helper so sudo doesn't try to
    # prompt on the TTY (which is unavailable over SSH). For key auth, sudo is
    # assumed to be configured to run find without a password.
    # We intentionally avoid piping through `sort` so that sudo/find's real
    # exit code propagates back — a pipe's exit code is from the last stage
    # (sort), which is always 0 even when find fails.
    find_cmd =
      if job.ssh_auth_method == "password" and job.ssh_password not in [nil, ""] do
        escaped = String.replace(job.ssh_password, "'", "'\\''")

        "AP=/tmp/.findask_$$; " <>
          "printf '#!/bin/sh\\necho '\"'\"'#{escaped}'\"'\"'\\n' > $AP; " <>
          "chmod 700 $AP; " <>
          "SUDO_ASKPASS=$AP sudo -A find '#{remote_path}' -type f -printf '%P\\n' 2>/dev/null; " <>
          "RC=$?; rm -f $AP; exit $RC"
      else
        "sudo find '#{remote_path}' -type f -printf '%P\\n' 2>/dev/null"
      end

    Logger.debug(
      "[UploadWorker] Job #{job.id}: listing #{job.remote_source_path} on #{job.ssh_host}"
    )

    with {:ok, sshpass_prefix, auth_args, env} <- ssh_auth_parts_from_job(job) do
      ssh = System.find_executable("ssh") || "ssh"

      # Build args as a proper list so find_cmd is passed as a single argument
      # to SSH. Joining into a string and using sh -c would let the local shell
      # split find_cmd's semicolons before SSH ever sees them.
      {executable, args} =
        if sshpass_prefix != "" do
          sshpass = sshpass_prefix |> String.split() |> hd()

          {sshpass,
           ["-e", ssh, "-p", port] ++
             auth_args ++ ["#{job.ssh_username}@#{job.ssh_host}", find_cmd]}
        else
          {ssh, ["-p", port] ++ auth_args ++ ["#{job.ssh_username}@#{job.ssh_host}", find_cmd]}
        end

      {output, code} =
        System.cmd(executable, args,
          stderr_to_stdout: false,
          env: env
        )

      if code == 0 do
        files =
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, files}
      else
        {:error, "SSH file listing failed (exit #{code}) for path: #{job.remote_source_path}"}
      end
    end
  end

  # Builds the --rsync-path value for the remote rsync invocation.
  # Mirrors remote_rsync_path/1 in Hostctl.Plesk.Importer.
  # For password auth, creates a tiny SUDO_ASKPASS helper on the remote so
  # that stdin stays free for rsync protocol data.
  defp remote_rsync_path_from_job(job) do
    if job.ssh_auth_method == "password" and job.ssh_password not in [nil, ""] do
      escaped = String.replace(job.ssh_password, "'", "'\\''")

      "sh -c '" <>
        "AP=/tmp/.rsync_askpass_$$; " <>
        "printf \"#!/bin/sh\\necho " <>
        "'\"'\"'" <>
        escaped <>
        "'\"'\"'" <>
        "\\n\" > $AP; " <>
        "chmod 700 $AP; " <>
        "SUDO_ASKPASS=$AP sudo -A rsync \"$@\"; " <>
        "RC=$?; rm -f $AP; exit $RC" <>
        "' rsync"
    else
      "sudo rsync"
    end
  end

  # Builds SSH auth args from the job's stored credentials.
  # Mirrors the logic in Hostctl.Plesk.Importer.ssh_auth_parts/1.
  defp ssh_auth_parts_from_job(job) do
    case job.ssh_auth_method do
      "password" ->
        password = job.ssh_password || ""

        case System.find_executable("sshpass") do
          nil ->
            {:error, "sshpass not found"}

          sshpass ->
            {:ok, "#{sshpass} -e", ["-o", "StrictHostKeyChecking=accept-new"],
             [{"SSHPASS", password}]}
        end

      _ ->
        key_path =
          (job.ssh_private_key_path || "")
          |> String.replace(~r{^~/}, System.user_home!() <> "/")

        {:ok, "",
         [
           "-o",
           "BatchMode=yes",
           "-o",
           "StrictHostKeyChecking=accept-new",
           "-i",
           key_path
         ], []}
    end
  end

  # ---------------------------------------------------------------------------
  # Shared upload helpers
  # ---------------------------------------------------------------------------

  defp get_existing_s3_keys(job) do
    case S3Client.list_all_keys(
           job.s3_endpoint,
           job.s3_bucket,
           job.s3_prefix,
           job.s3_access_key_id,
           job.s3_secret_access_key,
           job.s3_region
         ) do
      {:ok, keys} -> MapSet.new(keys)
      {:error, _} -> MapSet.new()
    end
  end

  defp s3_key(job, relative) do
    if job.s3_prefix && job.s3_prefix != "",
      do: "#{job.s3_prefix}/#{relative}",
      else: relative
  end

  defp upload_files(job, files, current_count, worker_pid) do
    # Process files in batches; check cancellation flag between batches
    # (the flag is set in the worker process dict by handle_cast :cancel)
    results =
      files
      |> Stream.with_index(current_count + 1)
      |> Stream.transform(:cont, fn {file_path, index}, _acc ->
        # Check the cancel flag (readable from worker process via send+receive)
        cancelled =
          if worker_pid == self() do
            Process.get(:cancel_upload, false)
          else
            false
          end

        if cancelled do
          {:halt, :halted}
        else
          {{:cont, {file_path, index}}, :cont}
        end
      end)
      |> Task.async_stream(
        fn {file_path, index} ->
          relative = Path.relative_to(file_path, job.source_path)

          key =
            if job.s3_prefix && job.s3_prefix != "",
              do: "#{job.s3_prefix}/#{relative}",
              else: relative

          # Update current file and progress
          {:ok, updated_job} =
            Hosting.update_upload_job(job, %{
              current_file: relative,
              uploaded_files: index - 1
            })

          broadcast_progress(updated_job)

          result =
            case S3Client.put_object(
                   job.s3_endpoint,
                   job.s3_bucket,
                   key,
                   file_path,
                   job.s3_access_key_id,
                   job.s3_secret_access_key,
                   job.s3_region
                 ) do
              :ok ->
                Logger.debug("[UploadWorker] Uploaded #{key}")
                :ok

              {:error, reason} ->
                Logger.warning("[UploadWorker] Failed to upload #{key}: #{inspect(reason)}")
                {:error, "#{relative}: #{inspect(reason)}"}
            end

          # Update progress after successful upload
          if result == :ok do
            {:ok, updated_job} = Hosting.update_upload_job(job, %{uploaded_files: index})
            broadcast_progress(updated_job)
          end

          result
        end,
        timeout: :infinity,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    # If cancelled, report paused with however many succeeded
    if Process.get(:cancel_upload, false) do
      success_count = Enum.count(results, &(&1 == :ok))
      {:paused, current_count + success_count}
    else
      errors = Enum.filter(results, &match?({:error, _}, &1))
      success_count = Enum.count(results, &(&1 == :ok))
      failed_count = length(errors)

      if errors == [] do
        {:ok, current_count + success_count}
      else
        {:error, errors, current_count + success_count, failed_count}
      end
    end
  end

  defp broadcast_progress(job) do
    Phoenix.PubSub.broadcast(@pubsub, "upload_jobs", {:upload_progress, job})
  end

  defp list_files_recursive(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      if File.dir?(full) do
        list_files_recursive(full)
      else
        [full]
      end
    end)
  rescue
    _ -> []
  end
end
