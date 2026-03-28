defmodule Hostctl.FtpServer do
  @moduledoc """
  Manages vsftpd virtual user configuration for hosted FTP accounts.

  When FTP accounts are created, updated, or deleted via the
  `Hostctl.Hosting` context, these functions update the vsftpd virtual users
  database and per-user configuration files, then reload vsftpd.

  vsftpd is configured to use PAM with `pam_userdb` for virtual user
  authentication. This module maintains:

    - `virtual_users_file` — a plaintext username/password list used as input
      for `db_load` to build the Berkeley DB auth database. The file is
      written with mode 0o600 and should reside in a root-owned directory.
    - `virtual_users_db` — path (without extension) of the generated `.db`
      file consumed by PAM.
    - `vsftpd_user_conf_dir/<username>` — per-user vsftpd override files that
      set `local_root` to restrict the account to its home directory.

  Operations are best-effort: failures are logged but do not roll back database
  changes (the same policy as `Hostctl.WebServer`).

  ## Configuration

      config :hostctl, :ftp_server,
        enabled: true,
        vsftpd_user_conf_dir: "/etc/vsftpd/vsftpd_user_conf",
        virtual_users_file: "/etc/vsftpd/virtual_users.txt",
        virtual_users_db: "/etc/vsftpd/virtual_users",
        db_load_cmd: "db_load",
        # Requires: hostctl ALL=(root) NOPASSWD: /usr/bin/systemctl reload vsftpd
        vsftpd_reload_cmd: ["sudo", "systemctl", "reload", "vsftpd"]

  Set `enabled: false` in test/dev environments to skip all filesystem and
  process operations.
  """

  require Logger

  alias Hostctl.Hosting.FtpAccount

  @doc """
  Provisions a new or updated FTP account on the vsftpd instance.

  Writes the per-user config file, adds/updates the entry in the virtual users
  password file, rebuilds the Berkeley DB, and reloads vsftpd.

  `raw_password` is the plaintext password string captured before hashing. Pass
  `nil` to skip updating the password entry (e.g. for a status-only change).
  """
  def provision_account(%FtpAccount{} = account, raw_password) do
    if enabled?() do
      case do_provision(account, raw_password) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[FtpServer] Failed to provision account #{account.username}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Removes an FTP account from vsftpd.

  Deletes the per-user config file, removes the user entry from the virtual
  users database, rebuilds the Berkeley DB, and reloads vsftpd.
  """
  def remove_account(%FtpAccount{} = account) do
    if enabled?() do
      case do_remove(account) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[FtpServer] Failed to remove account #{account.username}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private implementation
  # ---------------------------------------------------------------------------

  defp do_provision(%FtpAccount{} = account, raw_password) do
    with :ok <- write_user_conf(account),
         :ok <- upsert_user_entry(account.username, raw_password),
         :ok <- rebuild_user_db(),
         :ok <- reload() do
      :ok
    end
  end

  defp do_remove(%FtpAccount{} = account) do
    with :ok <- remove_user_conf(account),
         :ok <- delete_user_entry(account.username),
         :ok <- rebuild_user_db(),
         :ok <- reload() do
      :ok
    end
  end

  # Writes /etc/vsftpd/vsftpd_user_conf/<username> with a `local_root` override
  # so vsftpd chroots the virtual user to their configured home directory.
  defp write_user_conf(%FtpAccount{} = account) do
    dir = user_conf_dir()
    path = Path.join(dir, account.username)
    home_dir = account.home_dir || "/"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, "local_root=#{home_dir}\n") do
      :ok
    end
  end

  defp remove_user_conf(%FtpAccount{} = account) do
    path = Path.join(user_conf_dir(), account.username)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Adds or replaces the username/password pair in the plaintext users file.
  # When `raw_password` is nil the existing entry (if any) is left untouched.
  defp upsert_user_entry(_username, nil), do: :ok

  defp upsert_user_entry(username, raw_password) do
    file = virtual_users_file()

    with {:ok, existing} <- read_user_entries(file) do
      # Remove any pre-existing entry for this username, then append the new one.
      kept =
        existing
        |> Enum.reject(fn [u, _p] -> u == username end)
        |> Enum.flat_map(& &1)

      content = Enum.join(kept ++ [username, raw_password], "\n")

      with :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <- File.write(file, content <> "\n") do
        # Restrict readability: should be root-owned but at minimum not world-readable.
        File.chmod(file, 0o600)
        :ok
      end
    end
  end

  # Removes the given username's entry from the plaintext users file.
  defp delete_user_entry(username) do
    file = virtual_users_file()

    with {:ok, existing} <- read_user_entries(file) do
      remaining =
        existing
        |> Enum.reject(fn [u, _p] -> u == username end)
        |> Enum.flat_map(& &1)

      case remaining do
        [] ->
          case File.rm(file) do
            :ok -> :ok
            {:error, :enoent} -> :ok
            {:error, reason} -> {:error, reason}
          end

        lines ->
          File.write(file, Enum.join(lines, "\n") <> "\n")
      end
    end
  end

  # Reads the plaintext virtual users file and returns a list of [user, pass] pairs.
  # Returns {:ok, []} if the file does not exist yet.
  defp read_user_entries(file) do
    case File.read(file) do
      {:ok, content} ->
        entries =
          content
          |> String.split("\n", trim: true)
          |> Enum.chunk_every(2)
          |> Enum.filter(fn chunk -> length(chunk) == 2 end)

        {:ok, entries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Rebuilds the Berkeley DB file from the plaintext users file using db_load.
  defp rebuild_user_db do
    file = virtual_users_file()
    db = virtual_users_db()
    cmd = Keyword.get(config(), :db_load_cmd, "db_load")

    case System.cmd(cmd, ["-T", "-t", "hash", "-f", file, "#{db}.db"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, exit_code} ->
        Logger.error(
          "[FtpServer] db_load failed (exit #{exit_code}): #{String.trim(output)}"
        )

        {:error, {:db_load_failed, exit_code, output}}
    end
  end

  defp reload do
    cmd = Keyword.get(config(), :vsftpd_reload_cmd, ["sudo", "systemctl", "reload", "vsftpd"])
    [executable | args] = cmd

    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("[FtpServer] vsftpd reloaded successfully")
        :ok

      {output, exit_code} ->
        Logger.error(
          "[FtpServer] vsftpd reload failed (exit #{exit_code}): #{String.trim(output)}"
        )

        {:error, {:reload_failed, exit_code, output}}
    end
  end

  defp enabled?, do: Keyword.get(config(), :enabled, false)

  defp user_conf_dir,
    do: Keyword.get(config(), :vsftpd_user_conf_dir, "/etc/vsftpd/vsftpd_user_conf")

  defp virtual_users_file,
    do: Keyword.get(config(), :virtual_users_file, "/etc/vsftpd/virtual_users.txt")

  defp virtual_users_db,
    do: Keyword.get(config(), :virtual_users_db, "/etc/vsftpd/virtual_users")

  defp config, do: Application.get_env(:hostctl, :ftp_server, [])
end
