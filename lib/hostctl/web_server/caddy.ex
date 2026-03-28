defmodule Hostctl.WebServer.Caddy do
  @moduledoc """
  Generates Caddy web server configuration files for hosted domains.

  Each domain gets a config file under the `caddy_sites_dir` directory.
  The main Caddyfile should include these via `import sites-enabled/*`.

  Caddy automatically provisions TLS certificates via Let's Encrypt for
  any site block with a valid domain name (not just IP/localhost).
  """

  alias Hostctl.Hosting.Domain

  @doc """
  Returns the filename (not full path) for a domain's Caddy config.
  """
  def config_filename(%Domain{name: name}), do: "#{name}.conf"

  @doc """
  Generates a complete Caddy site block config for the given domain and its
  active subdomains.
  """
  def generate_config(%Domain{} = domain, subdomains \\ []) do
    if domain.status == "suspended" do
      generate_suspended_config(domain)
    else
      generate_active_config(domain, subdomains)
    end
  end

  defp generate_active_config(%Domain{} = domain, subdomains) do
    doc_root = domain.document_root || "/var/www/#{domain.name}/public"
    php_socket = php_fpm_socket(domain.php_version)

    main_block = """
    # #{domain.name} — managed by hostctl
    #{domain.name}, www.#{domain.name} {
    \troot * #{doc_root}
    \tencode gzip zstd
    \tphp_fastcgi #{php_socket}
    \tfile_server
    \tlog {
    \t\toutput file /var/log/caddy/#{domain.name}.log
    \t}
    }
    """

    subdomain_blocks =
      subdomains
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.map(fn sub ->
        sub_root =
          sub.document_root || "/var/www/#{domain.name}/subdomains/#{sub.name}/public"

        """
        # #{sub.name}.#{domain.name} — managed by hostctl
        #{sub.name}.#{domain.name} {
        \troot * #{sub_root}
        \tencode gzip zstd
        \tphp_fastcgi #{php_socket}
        \tfile_server
        }
        """
      end)

    Enum.join([main_block | subdomain_blocks], "\n")
  end

  defp generate_suspended_config(%Domain{} = domain) do
    """
    # #{domain.name} — managed by hostctl (suspended)
    #{domain.name}, www.#{domain.name} {
    \trespond "This website has been suspended." 503
    }
    """
  end

  defp php_fpm_socket(php_version) do
    pattern =
      Application.get_env(:hostctl, :web_server, [])
      |> Keyword.get(:php_fpm_socket_pattern, "/run/php/php{version}-fpm.sock")

    String.replace(pattern, "{version}", php_version || "8.3")
  end
end
