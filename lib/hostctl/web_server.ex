defmodule Hostctl.WebServer do
  @moduledoc """
  Manages Nginx virtual host configuration for hosted domains.

  When domains or subdomains are created, updated, or deleted via the
  `Hostctl.Hosting` context, these functions write per-domain Nginx vhost
  files to `sites-available`, symlink them into `sites-enabled`, and reload
  Nginx.

  Custom SSL certificates stored in the database are written to disk so Nginx
  can serve them. Let's Encrypt certificates are managed by Certbot and only
  referenced by path.

  Operations are best-effort: failures are logged but do not roll back database
  changes.

  ## Configuration

      config :hostctl, :web_server,
        enabled: true,
        nginx_sites_available_dir: "/etc/nginx/sites-available",
        nginx_sites_enabled_dir: "/etc/nginx/sites-enabled",
        nginx_reload_cmd: ["systemctl", "reload", "nginx"],
        ssl_dir: "/etc/ssl/hostctl",
        php_fpm_socket_pattern: "/run/php/php{version}-fpm.sock"

  Set `enabled: false` in test/dev environments to skip all filesystem and
  process operations.
  """

  require Logger

  import Ecto.Query

  alias Hostctl.Repo
  alias Hostctl.Hosting.{Domain, DomainProxy, Subdomain, SslCertificate, DomainS3Backend}
  alias Hostctl.WebServer.Nginx
  alias Hostctl.WebServer.RcloneMount

  @doc """
  Writes (or overwrites) the Nginx vhost config for the given domain, then
  reloads Nginx. Subdomains and the SSL certificate are fetched from the
  database automatically.
  """
  def sync_domain(%Domain{} = domain) do
    if enabled?() do
      domain = Repo.get!(Domain, domain.id)

      if domain.web_enabled do
        with {:ok, runtime} <- Hostctl.Isolation.Runtime.prepare_domain(domain) do
          do_sync_domain(domain, runtime)
        end
      else
        :ok
      end
    else
      :ok
    end
  end

  defp do_sync_domain(domain, runtime) do
    subdomains = Repo.all(from s in Subdomain, where: s.domain_id == ^domain.id)

    proxies =
      Repo.all(
        from p in DomainProxy,
          where: p.domain_id == ^domain.id and p.enabled == true,
          order_by: [asc: p.path]
      )

    ssl_cert = Repo.get_by(SslCertificate, domain_id: domain.id)
    s3_backends = Repo.all(from b in DomainS3Backend, where: b.domain_id == ^domain.id)

    if ssl_cert && ssl_cert.cert_type == "custom" && ssl_cert.status == "active" do
      write_ssl_cert(domain.name, ssl_cert)
    end

    # Ensure the document root exists before nginx tries to serve from it.
    # Skip subdomains whose root is managed by an ftp_mount_enabled S3 backend —
    # the mount point is the S3 bucket itself, so writing a placeholder index.html
    # would either land on the local filesystem (confusing) or get written into S3
    # via the FUSE mount (potentially overwriting real content).
    s3_mounted_subdomain_names =
      s3_backends
      |> Enum.filter(&(&1.ftp_mount_enabled && &1.url_path == ""))
      |> Enum.map(& &1.subdomain)
      |> MapSet.new()

    root_result =
      if runtime[:isolated] do
        :ok
      else
        roots =
          [domain.document_root || "/var/www/#{domain.name}/httpdocs"] ++
            (subdomains
             |> Enum.reject(&MapSet.member?(s3_mounted_subdomain_names, &1.name))
             |> Enum.map(
               &(&1.document_root || "/var/www/#{domain.name}/#{&1.name}.#{domain.name}")
             ))

        Enum.reduce_while(roots, :ok, fn root, :ok ->
          case provision_webroot(root) do
            {:error, _} = error -> {:halt, error}
            _ -> {:cont, :ok}
          end
        end)
      end

    with :ok <- root_result do
      config = Nginx.generate_config(domain, subdomains, ssl_cert, proxies, s3_backends, runtime)
      previous_config = File.read(sites_available_path(domain))
      previous_link = File.read_link(sites_enabled_path(domain))

      case write_vhost(domain, config) do
        :ok ->
          case reload() do
            :ok ->
              RcloneMount.sync_mounts(domain, subdomains, s3_backends)

            {:error, _} = error ->
              if runtime[:isolated], do: restore_vhost(domain, previous_config, previous_link)
              error
          end

        {:error, reason} ->
          Logger.error(
            "[WebServer] Failed to write Nginx config for #{domain.name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp restore_vhost(domain, previous_config, previous_link) do
    case previous_config do
      {:ok, content} -> File.write(sites_available_path(domain), content)
      {:error, :enoent} -> File.rm(sites_available_path(domain))
      _ -> :ok
    end

    File.rm(sites_enabled_path(domain))

    case previous_link do
      {:ok, target} -> File.ln_s(target, sites_enabled_path(domain))
      _ -> :ok
    end
  end

  @doc """
  Removes the Nginx vhost config files (sites-available and sites-enabled
  symlink) for the given domain, then reloads Nginx.

  Also removes custom SSL cert files from disk if they exist.
  """
  def remove_domain(%Domain{} = domain) do
    remove_domain(domain, [])
  end

  def remove_domain(%Domain{} = domain, opts) when is_list(opts) do
    if enabled?() do
      s3_backends = Repo.all(from b in DomainS3Backend, where: b.domain_id == ^domain.id)
      RcloneMount.remove_all(s3_backends)

      purge_result =
        if Keyword.get(opts, :purge_files, false) do
          purge_domain_content(domain)
        else
          :ok
        end

      available_path = sites_available_path(domain)
      enabled_path = sites_enabled_path(domain)

      file_errors =
        Enum.reduce([enabled_path, available_path], [], fn path, acc ->
          case File.rm(path) do
            :ok ->
              acc

            {:error, :enoent} ->
              acc

            {:error, reason} ->
              Logger.warning("[WebServer] Could not remove #{path}: #{inspect(reason)}")
              [{path, reason} | acc]
          end
        end)

      ssl_result = remove_ssl_cert(domain.name)
      reload_result = reload()

      cond do
        match?({:error, _}, purge_result) ->
          {:error, {:purge_failed, elem(purge_result, 1)}}

        file_errors != [] ->
          {:error, {:vhost_remove_failed, Enum.reverse(file_errors)}}

        ssl_result != :ok ->
          {:error, {:ssl_cleanup_failed, ssl_result}}

        match?({:error, _}, reload_result) ->
          {:error, reload_result}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Writes custom SSL certificate PEM files to `ssl_dir/<domain_name>/` so
  Nginx can reference them. Called automatically from `sync_domain/1` when a
  custom cert is active.
  """
  def write_ssl_cert(domain_name, %SslCertificate{certificate: cert, private_key: key})
      when is_binary(cert) and is_binary(key) do
    dir = Path.join(ssl_dir(), domain_name)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, "fullchain.pem"), cert),
         :ok <- File.write(Path.join(dir, "privkey.pem"), key) do
      # Restrict private key so only the service user can read it
      File.chmod(Path.join(dir, "privkey.pem"), 0o640)
      :ok
    end
  end

  def write_ssl_cert(_domain_name, _cert), do: :ok

  @doc """
  Reloads Nginx without dropping active connections. Uses the configured
  `nginx_reload_cmd` (default: `["systemctl", "reload", "nginx"]`).
  """
  def reload do
    if enabled?() do
      case validate_config() do
        :ok ->
          cmd =
            web_server_config()
            |> Keyword.get(:nginx_reload_cmd, ["sudo", "systemctl", "reload", "nginx"])

          [executable | args] = cmd

          case System.cmd(executable, args, stderr_to_stdout: true) do
            {_, 0} ->
              Logger.info("[WebServer] Nginx reloaded successfully")
              :ok

            {output, exit_code} ->
              Logger.error(
                "[WebServer] Nginx reload failed (exit #{exit_code}): #{String.trim(output)}"
              )

              {:error, {:reload_failed, exit_code, output}}
          end

        {:error, reason} ->
          Logger.error("[WebServer] Nginx config invalid — skipping reload: #{reason}")
          {:error, {:config_invalid, reason}}
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp write_vhost(%Domain{} = domain, config) do
    available = sites_available_path(domain)
    enabled = sites_enabled_path(domain)

    with :ok <- File.mkdir_p(Path.dirname(available)),
         :ok <- File.mkdir_p(Path.dirname(enabled)),
         :ok <- File.write(available, config) do
      # Remove any stale symlink before (re-)creating it
      File.rm(enabled)
      File.ln_s(available, enabled)
    end
  end

  # Creates a webroot directory and writes a default index.html if neither the
  # dir nor any index file already exists. This ensures nginx can serve the site
  # immediately after a domain is added, rather than returning 403/404.
  # Files are chowned to www-data so FTP virtual users (who run as www-data)
  # can manage them.
  defp provision_webroot(path) do
    Hostctl.Isolation.Runtime.legacy_webroot(path)
  end

  @doc "Recursively chown the given path to www-data:www-data via sudo."
  def chown_to_www_data(path) do
    with :ok <- Hostctl.Isolation.Runtime.legacy_write_allowed(path) do
      if Hostctl.Isolation.Runtime.enrolled?(),
        do: Hostctl.Isolation.Runtime.legacy_chown(path),
        else: do_chown_to_www_data(path)
    end
  end

  defp do_chown_to_www_data(path) do
    args = [
      "systemd-run",
      "--pipe",
      "--wait",
      "--collect",
      "--quiet",
      "/usr/bin/chown",
      "-R",
      "www-data:www-data",
      path
    ]

    case System.cmd("sudo", args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.warning(
          "[WebServer] Could not chown #{path} to www-data (exit #{code}): #{output}"
        )
    end
  end

  # Runs `nginx -t` to verify the full config before a reload.
  defp validate_config do
    cmd =
      web_server_config()
      |> Keyword.get(:nginx_validate_cmd, ["nginx", "-t"])

    [executable | args] = cmd

    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, _} ->
        # nginx -t exits non-zero if it can't open /run/nginx.pid (permission denied
        # when running as a non-root service user), even when the config syntax is
        # fine. Treat it as valid if the output explicitly says "syntax is ok".
        if String.contains?(output, "syntax is ok") do
          :ok
        else
          {:error, String.trim(output)}
        end
    end
  end

  defp remove_ssl_cert(domain_name) do
    dir = Path.join(ssl_dir(), domain_name)

    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, _} ->
        Logger.warning("[WebServer] Could not remove SSL dir #{dir}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp purge_domain_content(%Domain{} = domain) do
    subdomain_roots =
      Repo.all(
        from s in Subdomain,
          where: s.domain_id == ^domain.id,
          select: s.document_root
      )

    domain_base = domain_base_dir(domain)

    web_paths =
      [domain_base | subdomain_roots]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()

    with :ok <- validate_purge_paths(web_paths, &safe_web_purge_path?/1),
         :ok <- Enum.reduce_while(web_paths, :ok, &purge_path(&1, &2)),
         :ok <- purge_mail_path(domain.name) do
      :ok
    end
  end

  defp domain_base_dir(%Domain{} = domain) do
    case domain.document_root do
      path when is_binary(path) and path != "" -> Path.dirname(path)
      _ -> "/var/www/#{domain.name}"
    end
  end

  defp purge_mail_path(domain_name) do
    path = Path.expand(Path.join("/var/mail/vhosts", domain_name))

    if safe_mail_purge_path?(path) do
      case rm_rf_as_root(path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:mail_purge_failed, path, reason}}
      end
    else
      {:error, {:unsafe_mail_purge_path, path}}
    end
  end

  defp purge_path(path, :ok) do
    case rm_rf_as_root(path) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:web_purge_failed, path, reason}}}
    end
  end

  defp validate_purge_paths(paths, checker) do
    case Enum.find(paths, fn path -> not checker.(path) end) do
      nil -> :ok
      bad -> {:error, {:unsafe_web_purge_path, bad}}
    end
  end

  defp safe_web_purge_path?(path) do
    inside_prefix?(path, "/var/www") and path != "/var/www"
  end

  defp safe_mail_purge_path?(path) do
    inside_prefix?(path, "/var/mail/vhosts") and path != "/var/mail/vhosts"
  end

  defp inside_prefix?(path, prefix) do
    expanded = Path.expand(path)
    expanded == prefix or String.starts_with?(expanded, prefix <> "/")
  end

  defp rm_rf_as_root(path) do
    case System.cmd(
           "sudo",
           ["systemd-run", "--pipe", "--wait", "--collect", "--quiet", "rm", "-rf", "--", path],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        reason = String.trim(output)
        Logger.error("[WebServer] Could not purge #{path} (exit #{code}): #{reason}")
        {:error, {code, reason}}
    end
  end

  defp sites_available_path(%Domain{} = domain) do
    dir =
      web_server_config() |> Keyword.get(:nginx_sites_available_dir, "/etc/nginx/sites-available")

    Path.join(dir, Nginx.config_filename(domain))
  end

  defp sites_enabled_path(%Domain{} = domain) do
    dir = web_server_config() |> Keyword.get(:nginx_sites_enabled_dir, "/etc/nginx/sites-enabled")
    Path.join(dir, Nginx.config_filename(domain))
  end

  defp ssl_dir,
    do: web_server_config() |> Keyword.get(:ssl_dir, "/etc/ssl/hostctl")

  defp enabled?,
    do: web_server_config() |> Keyword.get(:enabled, true)

  defp web_server_config,
    do: Application.get_env(:hostctl, :web_server, [])
end
