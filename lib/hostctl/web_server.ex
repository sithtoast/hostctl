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
  alias Hostctl.Hosting.{Domain, Subdomain, SslCertificate}
  alias Hostctl.WebServer.Nginx

  @doc """
  Writes (or overwrites) the Nginx vhost config for the given domain, then
  reloads Nginx. Subdomains and the SSL certificate are fetched from the
  database automatically.
  """
  def sync_domain(%Domain{} = domain) do
    if enabled?() do
      # Re-fetch domain to ensure ssl_enabled and other fields are current
      domain = Repo.get!(Domain, domain.id)

      subdomains = Repo.all(from s in Subdomain, where: s.domain_id == ^domain.id)

      ssl_cert = Repo.get_by(SslCertificate, domain_id: domain.id)

      if ssl_cert && ssl_cert.cert_type == "custom" && ssl_cert.status == "active" do
        write_ssl_cert(domain.name, ssl_cert)
      end

      # Ensure the document root exists before nginx tries to serve from it
      provision_webroot(domain.document_root || "/var/www/#{domain.name}/public")

      Enum.each(subdomains, fn sub ->
        sub_root =
          sub.document_root ||
            "/var/www/#{domain.name}/subdomains/#{sub.name}/public"

        provision_webroot(sub_root)
      end)

      config = Nginx.generate_config(domain, subdomains, ssl_cert)

      case write_vhost(domain, config) do
        :ok ->
          reload()

        {:error, reason} ->
          Logger.error(
            "[WebServer] Failed to write Nginx config for #{domain.name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Removes the Nginx vhost config files (sites-available and sites-enabled
  symlink) for the given domain, then reloads Nginx.

  Also removes custom SSL cert files from disk if they exist.
  """
  def remove_domain(%Domain{} = domain) do
    if enabled?() do
      available_path = sites_available_path(domain)
      enabled_path = sites_enabled_path(domain)

      for path <- [enabled_path, available_path] do
        case File.rm(path) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            Logger.warning("[WebServer] Could not remove #{path}: #{inspect(reason)}")
        end
      end

      remove_ssl_cert(domain.name)
      reload()
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
  defp provision_webroot(path) do
    case File.mkdir_p(path) do
      :ok ->
        index = Path.join(path, "index.html")

        unless File.exists?(index) do
          File.write(index, default_index_html())
        end

      {:error, reason} ->
        Logger.warning("[WebServer] Could not create webroot #{path}: #{inspect(reason)}")
    end
  end

  defp default_index_html do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Site coming soon</title>
      <style>
        body { font-family: system-ui, sans-serif; display: flex; align-items: center;
               justify-content: center; min-height: 100vh; margin: 0;
               background: #f9fafb; color: #374151; }
        .card { text-align: center; padding: 2rem 3rem; background: white;
                border-radius: 0.75rem; box-shadow: 0 1px 3px rgba(0,0,0,.1); }
        h1 { font-size: 1.5rem; margin: 0 0 0.5rem; }
        p  { margin: 0; color: #6b7280; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>Site coming soon</h1>
        <p>Upload your files to get started.</p>
      </div>
    </body>
    </html>
    """
  end

  # Runs `nginx -t` to verify the full config before a reload.
  defp validate_config do
    cmd =
      web_server_config()
      |> Keyword.get(:nginx_validate_cmd, ["nginx", "-t"])

    [executable | args] = cmd

    case System.cmd(executable, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
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
