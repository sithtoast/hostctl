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

    # Broadcast start
    broadcast_progress(job)

    # Check which files already exist in S3 (for resume)
    existing_keys =
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

    # Get all files to upload
    all_files =
      job.source_path
      |> list_files_recursive()
      |> Enum.sort()

    # Filter out files that already exist
    files_to_upload =
      Enum.reject(all_files, fn file_path ->
        relative = Path.relative_to(file_path, job.source_path)

        key =
          if job.s3_prefix && job.s3_prefix != "",
            do: "#{job.s3_prefix}/#{relative}",
            else: relative

        MapSet.member?(existing_keys, key)
      end)

    total = length(all_files)
    already_uploaded = length(all_files) - length(files_to_upload)

    Logger.info(
      "[UploadWorker] Job #{job_id}: #{total} total files, #{already_uploaded} already uploaded, #{length(files_to_upload)} to upload"
    )

    # Update total files count
    {:ok, job} =
      Hosting.update_upload_job(job, %{total_files: total, uploaded_files: already_uploaded})

    # Upload remaining files (pass worker pid so stream can check cancellation)
    result = upload_files(job, files_to_upload, already_uploaded, self())

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

        # Clean up source directory if requested
        if get_in(job.metadata, ["cleanup_source"]) do
          File.rm_rf(job.source_path)
          Logger.debug("[UploadWorker] Cleaned up source directory: #{job.source_path}")
        end

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
