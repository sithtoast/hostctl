defmodule HostctlWeb.BackupDownloadController do
  use HostctlWeb, :controller

  alias Hostctl.Backup
  alias Hostctl.Backup.Log
  alias Hostctl.Backup.S3

  plug :require_admin

  def show(conn, %{"id" => id}) do
    with {log_id, ""} <- Integer.parse(id),
         %Log{} = log <- Backup.get_log(log_id) do
      download_log_archive(conn, log)
    else
      _ ->
        conn
        |> put_flash(:error, "Backup not found.")
        |> redirect(to: ~p"/panel/backups")
    end
  end

  defp download_log_archive(conn, %Log{} = log) do
    cond do
      local_archive_available?(log) ->
        send_download(conn, {:file, log.local_path}, filename: log_download_filename(log))

      s3_archive_available?(log) ->
        download_from_s3(conn, log)

      true ->
        conn
        |> put_flash(:error, "Backup archive is unavailable for download.")
        |> redirect(to: ~p"/panel/backups")
    end
  end

  defp download_from_s3(conn, %Log{} = log) do
    temp_path = temp_download_path(log)

    case S3.download(Backup.get_or_create_settings(), log.s3_key, temp_path) do
      {:ok, ^temp_path} ->
        conn
        |> register_before_send(fn conn ->
          _ = File.rm(temp_path)
          conn
        end)
        |> send_download({:file, temp_path}, filename: log_download_filename(log))

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_flash(:error, "Failed to download backup from S3: #{reason}")
        |> redirect(to: ~p"/panel/backups")
    end
  end

  defp require_admin(conn, _opts) do
    user = conn.assigns.current_scope && conn.assigns.current_scope.user

    if user && user.role == "admin" do
      conn
    else
      conn
      |> put_flash(:error, "You do not have permission to access this page.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  defp local_archive_available?(%Log{local_path: path}) when is_binary(path) and path != "" do
    File.regular?(path)
  end

  defp local_archive_available?(_), do: false

  defp s3_archive_available?(%Log{s3_key: key}) when is_binary(key) do
    String.ends_with?(key, ".tar.gz") or String.ends_with?(key, ".tgz")
  end

  defp s3_archive_available?(_), do: false

  defp temp_download_path(%Log{} = log) do
    extension =
      cond do
        is_binary(log.s3_key) && String.ends_with?(log.s3_key, ".tgz") -> ".tgz"
        true -> ".tar.gz"
      end

    Path.join(
      System.tmp_dir!(),
      "hostctl-backup-download-#{log.id}-#{System.system_time(:millisecond)}-#{:erlang.unique_integer([:positive])}#{extension}"
    )
  end

  defp log_download_filename(%Log{} = log) do
    candidate =
      cond do
        is_binary(log.local_path) and log.local_path != "" -> Path.basename(log.local_path)
        is_binary(log.s3_key) and log.s3_key != "" -> Path.basename(log.s3_key)
        true -> nil
      end

    if is_binary(candidate) and candidate != "" do
      candidate
    else
      stamp =
        if log.completed_at,
          do: Calendar.strftime(log.completed_at, "%Y%m%d-%H%M%S"),
          else: Integer.to_string(log.id || System.system_time(:second))

      "hostctl-backup-#{stamp}.tar.gz"
    end
  end
end
