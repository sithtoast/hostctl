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
        db_load_cmd: "db_load"

  All filesystem and process operations run via `systemd-run` to escape the
  service's `ProtectSystem=strict` mount namespace.

  Set `enabled: false` in test/dev environments to skip all operations.
  """

  require Logger

  alias Hostctl.Hosting.FtpAccount

  @ftp_roots_base "/var/ftproots"
  @systemd_unit_dir "/etc/systemd/system"

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

  defp do_provision(%FtpAccount{status: "suspended"} = account, _raw_password) do
    # Suspended accounts should be removed from vsftpd so they cannot authenticate.
    do_remove(account)
  end

  defp do_provision(%FtpAccount{} = account, raw_password) do
    with :ok <- write_user_conf(account),
         :ok <- teardown_all_mounts(account.username),
         :ok <- provision_mounts(account),
         :ok <- maybe_ensure_home_dir_writable(account),
         :ok <- upsert_user_entry(account.username, raw_password),
         :ok <- rebuild_user_db(),
         :ok <- reload() do
      :ok
    end
  end

  defp do_remove(%FtpAccount{} = account) do
    with :ok <- remove_user_conf(account),
         :ok <- teardown_all_mounts(account.username),
         :ok <- delete_user_entry(account.username),
         :ok <- rebuild_user_db(),
         :ok <- reload() do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Virtual directory / bind mount management
  # ---------------------------------------------------------------------------

  defp ftp_virtual_root(username), do: Path.join(@ftp_roots_base, username)
  defp mount_point(username, name), do: Path.join([@ftp_roots_base, username, name])

  # Provisions bind mounts for a multi-directory FTP account.
  # Creates /var/ftproots/<username>/ and one bind-mounted subdirectory per
  # mount entry, backed by a systemd .mount unit.
  defp provision_mounts(%FtpAccount{mounts: mounts}) when mounts in [nil, []], do: :ok

  defp provision_mounts(%FtpAccount{username: username, mounts: mounts}) do
    virtual_root = ftp_virtual_root(username)

    with :ok <- escaped_mkdir_p(virtual_root),
         {_, 0} <- escaped_cmd("chown", ["www-data:www-data", virtual_root]) do
      Enum.reduce_while(mounts, :ok, fn %{"name" => name, "path" => path}, :ok ->
        mp = mount_point(username, name)
        unit_name = systemd_mount_unit_name(mp)
        unit_path = Path.join(@systemd_unit_dir, unit_name)
        unit_content = mount_unit_content(username, name, path, mp)

        case provision_one_mount(mp, unit_name, unit_path, unit_content) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    else
      {:error, _} = err -> err
      {output, code} -> {:error, {:setup_virtual_root_failed, code, output}}
    end
  end

  defp provision_one_mount(mp, unit_name, unit_path, unit_content) do
    with :ok <- escaped_mkdir_p(mp),
         {_, 0} <- escaped_cmd("chown", ["www-data:www-data", mp]),
         :ok <- escaped_write(unit_path, unit_content),
         {_, 0} <- escaped_cmd("systemctl", ["daemon-reload"]),
         {_, 0} <- escaped_cmd("systemctl", ["enable", "--now", unit_name]) do
      :ok
    else
      {:error, _} = err -> err
      {output, code} -> {:error, {:command_failed, code, output}}
    end
  end

  # Tears down all systemd .mount units and the virtual root for a user.
  # Safe to call even if no mounts exist — it becomes a no-op.
  defp teardown_all_mounts(username) do
    escaped_username = systemd_escape_component(username)
    prefix = "var-ftproots-#{escaped_username}-"

    case escaped_cmd("sh", ["-c", "ls /etc/systemd/system/*.mount 2>/dev/null || true"],
           stderr_to_stdout: true
         ) do
      {output, _} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&(Path.basename(&1) |> String.starts_with?(prefix)))
        |> Enum.each(fn unit_path ->
          unit_name = Path.basename(unit_path)
          escaped_cmd("systemctl", ["disable", "--now", unit_name], stderr_to_stdout: true)
          escaped_cmd("rm", ["-f", unit_path], stderr_to_stdout: true)
        end)
    end

    escaped_cmd("systemctl", ["daemon-reload"], stderr_to_stdout: true)
    escaped_cmd("rm", ["-rf", ftp_virtual_root(username)], stderr_to_stdout: true)
    :ok
  end

  # Computes the systemd .mount unit name for a given absolute path.
  # Strips the leading "/", splits on "/", escapes each component
  # (replacing any non-alphanumeric/non-dot/non-underscore character with
  # \xNN hex notation), then joins with "-" and appends ".mount".
  # Example: /var/ftproots/john/example.com  => var-ftproots-john-example.com.mount
  # Example: /var/ftproots/my-user/site.com  => var-ftproots-my\x2duser-site.com.mount
  defp systemd_mount_unit_name(path) do
    path
    |> String.trim_leading("/")
    |> String.split("/")
    |> Enum.map(&systemd_escape_component/1)
    |> Enum.join("-")
    |> Kernel.<>(".mount")
  end

  defp systemd_escape_component(component) do
    for <<byte <- component>>, into: "" do
      char = <<byte>>

      if char =~ ~r/[A-Za-z0-9_.]/ do
        char
      else
        hex =
          byte
          |> Integer.to_string(16)
          |> String.downcase()
          |> String.pad_leading(2, "0")

        "\\x#{hex}"
      end
    end
  end

  defp mount_unit_content(username, name, source_path, mount_point) do
    """
    [Unit]
    Description=hostctl FTP virtual directory #{username}/#{name}
    Before=vsftpd.service

    [Mount]
    What=#{source_path}
    Where=#{mount_point}
    Type=none
    Options=bind

    [Install]
    WantedBy=multi-user.target
    """
  end

  # Ensures the home directory is set up for single-directory accounts.
  # Skipped when the account uses virtual bind mounts.
  defp maybe_ensure_home_dir_writable(%FtpAccount{mounts: mounts}) when mounts not in [nil, []] do
    :ok
  end

  defp maybe_ensure_home_dir_writable(%FtpAccount{} = account) do
    ensure_home_dir_writable(account)
  end

  # vsftpd maps all virtual users to guest_username=www-data, so the home
  # directory must be writable by www-data for uploads to succeed.
  defp ensure_home_dir_writable(%FtpAccount{home_dir: nil}), do: :ok

  defp ensure_home_dir_writable(%FtpAccount{home_dir: home_dir}) do
    with :ok <- escaped_mkdir_p(home_dir) do
      # Recursively chown so subdirectories (e.g. public/ inside the domain root)
      # are also writable by www-data, not just the top-level chroot directory.
      case escaped_cmd("chown", ["-R", "www-data:www-data", home_dir]) do
        {_, 0} ->
          :ok

        {output, code} ->
          Logger.warning(
            "[FtpServer] Could not chown #{home_dir} to www-data (exit #{code}): #{output}"
          )

          :ok
      end
    end
  end

  # Writes /etc/vsftpd/vsftpd_user_conf/<username> with a `local_root` override
  # so vsftpd chroots the virtual user to their configured root directory.
  # For multi-directory accounts, local_root points to the virtual bind-mount
  # root rather than a single home_dir.
  defp write_user_conf(%FtpAccount{} = account) do
    dir = user_conf_dir()
    path = Path.join(dir, account.username)

    local_root =
      if account.mounts && account.mounts != [] do
        ftp_virtual_root(account.username)
      else
        account.home_dir || "/"
      end

    content = """
    local_root=#{local_root}
    write_enable=YES
    virtual_use_local_privs=YES
    """

    with :ok <- escaped_mkdir_p(dir),
         :ok <- escaped_write(path, content) do
      :ok
    end
  end

  defp remove_user_conf(%FtpAccount{} = account) do
    path = Path.join(user_conf_dir(), account.username)

    case escaped_cmd("rm", ["-f", path]) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:rm_failed, code, output}}
    end
  end

  # Adds or replaces the username/password pair in the plaintext users file.
  # When `raw_password` is nil the existing entry (if any) is left untouched.
  defp upsert_user_entry(_username, nil), do: :ok

  defp upsert_user_entry(username, raw_password) do
    file = virtual_users_file()

    with {:ok, existing} <- read_user_entries(file),
         {:ok, hashed} <- sha512_crypt(raw_password) do
      # Remove any pre-existing entry for this username, then append the new one.
      kept =
        existing
        |> Enum.reject(fn [u, _p] -> u == username end)
        |> Enum.flat_map(& &1)

      content = Enum.join(kept ++ [username, hashed], "\n")

      with :ok <- escaped_mkdir_p(Path.dirname(file)),
           :ok <- escaped_write(file, content <> "\n"),
           :ok <- escaped_chmod("600", file) do
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
          # Write an empty file rather than deleting it so that rebuild_user_db
          # always has a source file and db_load does not fail with "No such
          # file or directory".  An empty DB means pam_userdb denies all logins.
          escaped_write(file, "")

        lines ->
          escaped_write(file, Enum.join(lines, "\n") <> "\n")
      end
    end
  end

  # Reads the plaintext virtual users file and returns a list of [user, pass] pairs.
  # Returns {:ok, []} if the file does not exist yet.
  defp read_user_entries(file) do
    case escaped_cmd("cat", [file], stderr_to_stdout: true) do
      {content, 0} ->
        entries =
          content
          |> String.split("\n", trim: true)
          |> Enum.chunk_every(2)
          |> Enum.filter(fn chunk -> length(chunk) == 2 end)

        {:ok, entries}

      {output, _code} ->
        # File doesn't exist or can't be read
        if String.contains?(output, "No such file") do
          {:ok, []}
        else
          {:error, {:read_failed, output}}
        end
    end
  end

  # Rebuilds the Berkeley DB file from the plaintext users file using db_load.
  defp rebuild_user_db do
    file = virtual_users_file()
    db = virtual_users_db()
    cmd = Keyword.get(config(), :db_load_cmd, "db_load")

    case escaped_cmd(cmd, ["-T", "-t", "hash", "-f", file, "#{db}.db"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _exit_code} when is_binary(output) ->
        if output =~ "No such file or directory" do
          # Source file was removed before rebuild was called. Remove the stale
          # DB so pam_userdb denies all logins cleanly rather than using old data.
          Logger.info("[FtpServer] Virtual users file absent — removing stale DB")
          escaped_cmd("rm", ["-f", "#{db}.db"])
          :ok
        else
          Logger.error("[FtpServer] db_load failed: #{String.trim(output)}")
          {:error, {:db_load_failed, output}}
        end
    end
  end

  defp reload do
    # Reload vsftpd via systemd-run to escape the ProtectSystem namespace.
    case escaped_cmd("systemctl", ["reload", "vsftpd"], stderr_to_stdout: true) do
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

  # ---------------------------------------------------------------------------
  # systemd-run helpers — escape ProtectSystem=strict namespace
  # ---------------------------------------------------------------------------

  # Runs a command in a transient systemd unit outside the service's
  # ProtectSystem mount namespace.
  defp escaped_cmd(cmd, args, opts \\ []) do
    systemd_args = ["systemd-run", "--pipe", "--wait", "--collect", "--quiet", cmd | args]
    System.cmd("sudo", systemd_args, opts)
  end

  defp escaped_mkdir_p(dir) do
    case escaped_cmd("mkdir", ["-p", dir]) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:mkdir_failed, code, output}}
    end
  end

  defp escaped_chmod(mode, path) do
    case escaped_cmd("chmod", [mode, path]) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:chmod_failed, code, output}}
    end
  end

  # Writes file content via systemd-run tee (clean namespace can access /etc).
  defp escaped_write(path, content) do
    encoded = Base.encode64(content)

    case System.cmd(
           "sh",
           [
             "-c",
             ~s(echo '#{encoded}' | base64 -d | sudo systemd-run --pipe --wait --collect --quiet tee -- "$1" > /dev/null),
             "--",
             path
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:write_failed, code, output}}
    end
  end

  # Hashes a plaintext password with SHA-512 crypt (the $6$ format understood
  # by pam_userdb when configured with crypt=crypt). The password is passed via
  # an environment variable so it never appears in the process list.
  defp sha512_crypt(password) do
    # Build a 16-char salt from the crypt(3)-safe alphabet [./A-Za-z0-9].
    chars = ~c"./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

    salt =
      :crypto.strong_rand_bytes(16)
      |> :binary.bin_to_list()
      |> Enum.map(&Enum.at(chars, rem(&1, 64)))
      |> to_string()

    case System.cmd(
           "sh",
           ["-c", "printf '%s' \"$_FTP_PW\" | openssl passwd -6 -salt \"$_FTP_SALT\" -stdin"],
           env: [{"_FTP_PW", password}, {"_FTP_SALT", salt}],
           stderr_to_stdout: true
         ) do
      {hash, 0} -> {:ok, String.trim(hash)}
      {output, code} -> {:error, {:hash_failed, code, output}}
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
