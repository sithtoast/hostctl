defmodule Hostctl.WebServer do
  @moduledoc """
  Manages Caddy web server configuration for hosted domains.

  When domains or subdomains are created, updated, or deleted via the
  `Hostctl.Hosting` context, these functions write per-domain Caddy config
  files and reload the web server.

  Operations are best-effort: if writing a config file or reloading Caddy
  fails, the error is logged but the database operation is not rolled back.

  ## Configuration

      config :hostctl, :web_server,
        enabled: true,
        caddy_sites_dir: "/etc/caddy/sites-enabled",
        caddy_reload_cmd: ["caddy", "reload", "--config", "/etc/caddy/Caddyfile"],
        php_fpm_socket_pattern: "/run/php/php{version}-fpm.sock"

  Set `enabled: false` in test/dev environments to skip all file system and
  process operations.
  """

  require Logger

  import Ecto.Query

  alias Hostctl.Repo
  alias Hostctl.Hosting.{Domain, Subdomain}
  alias Hostctl.WebServer.Caddy

  @doc """
  Writes (or overwrites) the Caddy config for the given domain, then reloads
  Caddy. Subdomains are fetched automatically from the database.
  """
  def sync_domain(%Domain{} = domain) do
    if enabled?() do
      subdomains = Repo.all(from s in Subdomain, where: s.domain_id == ^domain.id)
      config = Caddy.generate_config(domain, subdomains)

      case write_config(domain, config) do
        :ok ->
          reload()

        {:error, reason} ->
          Logger.error(
            "[WebServer] Failed to write Caddy config for #{domain.name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Removes the Caddy config file for the given domain, then reloads Caddy.
  """
  def remove_domain(%Domain{} = domain) do
    if enabled?() do
      path = config_path(domain)

      case File.rm(path) do
        :ok ->
          reload()

        {:error, :enoent} ->
          # Config file never existed — nothing to do.
          :ok

        {:error, reason} ->
          Logger.error(
            "[WebServer] Failed to remove Caddy config for #{domain.name}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Sends a reload signal to Caddy so it picks up any config changes without
  dropping existing connections.
  """
  def reload do
    if enabled?() do
      config = web_server_config()

      cmd =
        Keyword.get(config, :caddy_reload_cmd, [
          "caddy",
          "reload",
          "--config",
          "/etc/caddy/Caddyfile"
        ])

      [executable | args] = cmd

      case System.cmd(executable, args, stderr_to_stdout: true) do
        {_, 0} ->
          Logger.info("[WebServer] Caddy reloaded successfully")
          :ok

        {output, exit_code} ->
          Logger.error(
            "[WebServer] Caddy reload failed (exit #{exit_code}): #{String.trim(output)}"
          )

          {:error, {:reload_failed, exit_code, output}}
      end
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp write_config(%Domain{} = domain, config) do
    path = config_path(domain)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir) do
      File.write(path, config)
    end
  end

  defp config_path(%Domain{} = domain) do
    sites_dir =
      web_server_config()
      |> Keyword.get(:caddy_sites_dir, "/etc/caddy/sites-enabled")

    Path.join(sites_dir, Caddy.config_filename(domain))
  end

  defp enabled? do
    web_server_config()
    |> Keyword.get(:enabled, true)
  end

  defp web_server_config do
    Application.get_env(:hostctl, :web_server, [])
  end
end
