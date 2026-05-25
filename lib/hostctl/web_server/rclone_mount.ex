defmodule Hostctl.WebServer.RcloneMount do
  @moduledoc """
  Manages rclone FUSE mounts for S3-backed domains, enabling transparent FTP
  access to S3 storage.

  When `ftp_mount_enabled` is set on a `DomainS3Backend`, this module:
    1. Writes an rclone config file containing S3 credentials to
       `/etc/hostctl/rclone/backend-{id}.conf` (mode 0600).
    2. Writes a systemd service unit to
       `/etc/systemd/system/hostctl-s3-mount-{id}.service`.
    3. Enables and starts the service so rclone mounts the S3 bucket at the
       document root for the backend's scope.

  With the FUSE mount in place, vsftpd (and any other filesystem tool) can
  read from and write to the S3 bucket as if it were a local directory.
  nginx continues to proxy HTTP requests independently via `S3ProxyController`.

  ## Server prerequisites

  - `rclone` must be installed (`/usr/bin/rclone`).
  - `/etc/fuse.conf` must contain `user_allow_other` so non-root processes
    (nginx, vsftpd running as www-data) can traverse the mount.
  - The hostctl service user requires sudoers entries for `systemctl` and the
    file operations performed here (cp, chmod, mkdir).

  ## Configuration

  Same `:web_server` config key as `Hostctl.WebServer`. Set `enabled: false`
  to skip all operations in test/dev environments.
  """

  require Logger

  alias Hostctl.Hosting.{Domain, DomainS3Backend}

  @rclone_config_dir "/etc/hostctl/rclone"
  @systemd_unit_dir "/etc/systemd/system"
  @cache_base_dir "/var/cache/hostctl/rclone"
  @log_dir "/var/log/hostctl"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Synchronises rclone mounts for all S3 backends belonging to a domain.

  - Backends with `ftp_mount_enabled: true`, `enabled: true`, and credentials
    get their mount written and (re)started.
  - All other backends have their mount torn down if it was previously running.

  Called from `Hostctl.WebServer.sync_domain/1` after nginx is reloaded.
  """
  def sync_mounts(%Domain{} = domain, subdomains, backends) do
    if enabled?() do
      {active, inactive} =
        Enum.split_with(backends, fn b ->
          b.enabled && b.ftp_mount_enabled && has_credentials?(b)
        end)

      Enum.each(inactive, &teardown_mount/1)

      Enum.each(active, fn backend ->
        point = mount_point(backend, domain, subdomains)
        setup_mount(backend, point)
      end)
    end

    :ok
  end

  @doc """
  Tears down all mounts for the given list of backends.

  Called from `Hostctl.WebServer.remove_domain/1` before the nginx config is
  removed, so the mount has a chance to stop cleanly.
  """
  def remove_all(backends) do
    if enabled?() do
      Enum.each(backends, &teardown_mount/1)
    end

    :ok
  end

  @doc """
  Returns the filesystem path where the S3 bucket should be mounted for the
  given backend, domain, and subdomains list.
  """
  def mount_point(%DomainS3Backend{} = backend, %Domain{} = domain, subdomains) do
    base_root =
      if backend.subdomain == "" do
        domain.document_root || "/var/www/#{domain.name}/httpdocs"
      else
        sub = Enum.find(subdomains, fn s -> s.name == backend.subdomain end)

        cond do
          sub && sub.document_root -> sub.document_root
          sub -> "/var/www/#{domain.name}/#{sub.name}.#{domain.name}"
          true -> "/var/www/#{domain.name}/#{backend.subdomain}.#{domain.name}"
        end
      end

    if backend.url_path == "" do
      base_root
    else
      Path.join(base_root, backend.url_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Path helpers (visible for testing)
  # ---------------------------------------------------------------------------

  def service_name(backend_id), do: "hostctl-s3-mount-#{backend_id}.service"

  def config_path(backend_id),
    do: Path.join(@rclone_config_dir, "backend-#{backend_id}.conf")

  def unit_path(backend_id),
    do: Path.join(@systemd_unit_dir, service_name(backend_id))

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp setup_mount(%DomainS3Backend{} = backend, mount_point) do
    Logger.info("[RcloneMount] Setting up mount for backend #{backend.id} at #{mount_point}")

    with :ok <- ensure_dir_as_root(@rclone_config_dir, "700"),
         :ok <- ensure_dir_as_root(@cache_base_dir, "755"),
         :ok <- ensure_dir_as_root(@log_dir, "755"),
         :ok <- write_as_root(config_path(backend.id), rclone_config_content(backend), "600"),
         :ok <-
           write_as_root(unit_path(backend.id), service_unit_content(backend, mount_point), "644") do
      systemctl(["daemon-reload"])
      systemctl(["enable", service_name(backend.id)])
      systemctl(["restart", service_name(backend.id)])
    else
      {:error, reason} ->
        Logger.error(
          "[RcloneMount] Failed to set up mount for backend #{backend.id}: #{inspect(reason)}"
        )
    end
  end

  defp teardown_mount(%DomainS3Backend{} = backend) do
    service = service_name(backend.id)
    unit = unit_path(backend.id)

    if File.exists?(unit) do
      Logger.info("[RcloneMount] Tearing down mount for backend #{backend.id}")
      systemctl(["stop", service])
      systemctl(["disable", service])
      remove_as_root(unit)
      remove_as_root(config_path(backend.id))
      systemctl(["daemon-reload"])
    end
  end

  defp rclone_config_content(%DomainS3Backend{} = b) do
    endpoint = String.trim_trailing(b.endpoint_url || "", "/")
    region = if b.region && b.region != "", do: b.region, else: "us-east-1"

    # Written with mode 0600 — plaintext credentials on disk are unavoidable
    # for rclone; mitigate via restricted filesystem permissions.
    """
    [remote]
    type = s3
    provider = Other
    env_auth = false
    access_key_id = #{b.access_key_id}
    secret_access_key = #{b.secret_access_key}
    endpoint = #{endpoint}
    region = #{region}
    """
  end

  defp service_unit_content(%DomainS3Backend{} = b, mount_point) do
    config = config_path(b.id)
    cache = Path.join(@cache_base_dir, "backend-#{b.id}")
    log = Path.join(@log_dir, "rclone-backend-#{b.id}.log")

    s3_target =
      if b.path_prefix && b.path_prefix != "" do
        prefix = String.trim_leading(b.path_prefix, "/")
        "remote:#{b.bucket}/#{prefix}"
      else
        "remote:#{b.bucket}"
      end

    scope_desc =
      cond do
        b.subdomain != "" && b.url_path != "" -> "#{b.subdomain}.*#{b.url_path}"
        b.subdomain != "" -> "#{b.subdomain}.*"
        b.url_path != "" -> b.url_path
        true -> "whole domain"
      end

    # NOTE: /etc/fuse.conf must contain `user_allow_other` for nginx/vsftpd
    # (running as www-data) to access this mount.
    """
    # Managed by hostctl — do not edit manually
    [Unit]
    Description=Rclone S3 mount — #{scope_desc} — #{service_name(b.id)}
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=notify
    ExecStartPre=/bin/mkdir -p #{mount_point}
    ExecStart=/usr/bin/rclone mount --config #{config} --allow-other --vfs-cache-mode writes --cache-dir #{cache} --log-level ERROR --log-file #{log} #{s3_target} #{mount_point}
    ExecStop=/bin/fusermount -uz #{mount_point}
    KillMode=process
    Restart=on-failure
    RestartSec=15
    TimeoutStartSec=30

    [Install]
    WantedBy=multi-user.target
    """
  end

  # Runs a systemctl subcommand via sudo.
  defp systemctl(args) do
    case System.cmd("sudo", ["systemctl" | args], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.warning(
          "[RcloneMount] systemctl #{Enum.join(args, " ")} failed (#{code}): #{String.trim(output)}"
        )

        {:error, {code, output}}
    end
  end

  # Writes `content` to `path` as root using base64-encoded stdin piped
  # through systemd-run tee (the same technique as write_file_via_sudo in
  # FeatureSetup). A temp-file + sudo-cp approach does NOT work here because
  # systemd-run runs in an isolated mount namespace where /tmp is not shared.
  defp write_as_root(path, content, mode_octal_str) do
    encoded = Base.encode64(content)

    script =
      "echo '#{encoded}' | base64 -d | sudo systemd-run --pipe --wait --collect --quiet tee -- \"$1\" > /dev/null"

    case System.cmd("sh", ["-c", script, "--", path], stderr_to_stdout: true) do
      {_, 0} ->
        case System.cmd(
               "sudo",
               [
                 "systemd-run",
                 "--pipe",
                 "--wait",
                 "--collect",
                 "--quiet",
                 "/bin/chmod",
                 mode_octal_str,
                 path
               ],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {output, code} -> {:error, {:chmod_failed, code, output}}
        end

      {output, code} ->
        {:error, {:write_failed, code, output}}
    end
  end

  # Creates a directory as root if it does not already exist and sets mode.
  defp ensure_dir_as_root(path, mode_octal_str) do
    case System.cmd(
           "sudo",
           [
             "systemd-run",
             "--pipe",
             "--wait",
             "--collect",
             "--quiet",
             "/bin/mkdir",
             "-p",
             path
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        case System.cmd(
               "sudo",
               [
                 "systemd-run",
                 "--pipe",
                 "--wait",
                 "--collect",
                 "--quiet",
                 "/bin/chmod",
                 mode_octal_str,
                 path
               ],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {output, code} -> {:error, {:chmod_failed, code, output}}
        end

      {output, code} ->
        {:error, {:mkdir_failed, code, output}}
    end
  end

  # Removes a file as root.
  defp remove_as_root(path) do
    case System.cmd(
           "sudo",
           [
             "systemd-run",
             "--pipe",
             "--wait",
             "--collect",
             "--quiet",
             "/bin/rm",
             "-f",
             path
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:rm_failed, code, output}}
    end
  end

  defp has_credentials?(%DomainS3Backend{} = b) do
    is_binary(b.access_key_id) && b.access_key_id != "" &&
      is_binary(b.secret_access_key) && b.secret_access_key != ""
  end

  defp enabled? do
    Application.get_env(:hostctl, :web_server, []) |> Keyword.get(:enabled, true)
  end
end
