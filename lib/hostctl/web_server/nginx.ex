defmodule Hostctl.WebServer.Nginx do
  @moduledoc """
  Generates Nginx virtual host configuration files for hosted domains.

  Each domain gets a config file written to `nginx_sites_available_dir`, then
  symlinked into `nginx_sites_enabled_dir`. This matches the standard Debian/
  Ubuntu nginx layout.

  SSL is supported in two modes:

    - `lets_encrypt` — references Certbot-managed certs under
      the configured `letsencrypt_dir` (default `/var/lib/hostctl/letsencrypt/live/<domain>/`)
    - `custom` — references PEM files written to `ssl_dir/<domain>/` on disk
      by `Hostctl.WebServer.write_ssl_cert/2` when a certificate is saved

  When `domain.ssl_enabled` is true and an active `SslCertificate` exists, the
  config emits an HTTP→HTTPS redirect block and a full TLS server block.
  Otherwise only an HTTP server block is written.
  """

  alias Hostctl.Hosting.Domain
  alias Hostctl.Hosting.SslCertificate

  @doc "Returns the filename (not the full path) for a domain's Nginx vhost config."
  def config_filename(%Domain{name: name}), do: "#{name}.conf"

  @doc """
  Generates a complete Nginx vhost config for the given domain and its active
  subdomains. Pass the domain's `SslCertificate` record (or nil) to control
  whether SSL server blocks are included.
  """
  def generate_config(%Domain{} = domain, subdomains \\ [], ssl_cert \\ nil) do
    if domain.status == "suspended" do
      suspended_config(domain)
    else
      active_config(domain, subdomains, ssl_cert)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp active_config(%Domain{} = domain, subdomains, ssl_cert) do
    doc_root = domain.document_root || "/var/www/#{domain.name}/public"
    php_socket = php_fpm_socket(domain.php_version)
    use_ssl = ssl_active?(domain, ssl_cert)

    main =
      vhost_block(
        domain.name,
        "#{domain.name} www.#{domain.name}",
        doc_root,
        php_socket,
        use_ssl,
        ssl_cert
      )

    sub_blocks =
      subdomains
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.map(fn sub ->
        sub_root =
          sub.document_root ||
            "/var/www/#{domain.name}/subdomains/#{sub.name}/public"

        vhost_block(
          "#{sub.name}.#{domain.name}",
          "#{sub.name}.#{domain.name}",
          sub_root,
          php_socket,
          false,
          nil
        )
      end)

    Enum.join([main | sub_blocks], "\n")
  end

  defp vhost_block(log_name, server_names, doc_root, php_socket, false = _ssl, _cert) do
    """
    # #{log_name} — managed by hostctl
    server {
        listen 80;
        listen [::]:80;
        server_name #{server_names};

        root #{doc_root};
        index index.php index.html index.htm;

        access_log /var/log/nginx/#{log_name}.access.log;
        error_log /var/log/nginx/#{log_name}.error.log;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~ \\.php$ {
            fastcgi_pass unix:#{php_socket};
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
            include fastcgi_params;
            fastcgi_read_timeout 300;
        }

        location ~ /\\.ht {
            deny all;
        }
    }
    """
  end

  defp vhost_block(log_name, server_names, doc_root, php_socket, true = _ssl, ssl_cert) do
    primary = server_names |> String.split(" ") |> hd()
    ssl_cert_path = cert_path(ssl_cert, primary)
    ssl_key_path = key_path(ssl_cert, primary)

    """
    # #{log_name} — managed by hostctl
    server {
        listen 80;
        listen [::]:80;
        server_name #{server_names};
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name #{server_names};

        ssl_certificate #{ssl_cert_path};
        ssl_certificate_key #{ssl_key_path};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;
        ssl_prefer_server_ciphers on;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;

        root #{doc_root};
        index index.php index.html index.htm;

        access_log /var/log/nginx/#{log_name}.access.log;
        error_log /var/log/nginx/#{log_name}.error.log;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~ \\.php$ {
            fastcgi_pass unix:#{php_socket};
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
            include fastcgi_params;
            fastcgi_read_timeout 300;
        }

        location ~ /\\.ht {
            deny all;
        }
    }
    """
  end

  defp suspended_config(%Domain{} = domain) do
    """
    # #{domain.name} — managed by hostctl (suspended)
    server {
        listen 80;
        listen [::]:80;
        server_name #{domain.name} www.#{domain.name};

        location / {
            return 503 "This website has been suspended.";
        }
    }
    """
  end

  defp ssl_active?(%Domain{ssl_enabled: true}, %SslCertificate{status: "active"}), do: true
  defp ssl_active?(_, _), do: false

  defp cert_path(%SslCertificate{cert_type: "lets_encrypt"}, domain_name),
    do: Path.join(letsencrypt_dir(), "live/#{domain_name}/fullchain.pem")

  defp cert_path(%SslCertificate{cert_type: "custom"}, domain_name),
    do: Path.join(ssl_dir(), "#{domain_name}/fullchain.pem")

  defp key_path(%SslCertificate{cert_type: "lets_encrypt"}, domain_name),
    do: Path.join(letsencrypt_dir(), "live/#{domain_name}/privkey.pem")

  defp key_path(%SslCertificate{cert_type: "custom"}, domain_name),
    do: Path.join(ssl_dir(), "#{domain_name}/privkey.pem")

  defp ssl_dir,
    do:
      Application.get_env(:hostctl, :web_server, [])
      |> Keyword.get(:ssl_dir, "/etc/ssl/hostctl")

  defp letsencrypt_dir,
    do:
      Application.get_env(:hostctl, :certbot, [])
      |> Keyword.get(:letsencrypt_dir, "/var/lib/hostctl/letsencrypt")

  defp php_fpm_socket(php_version) do
    pattern =
      Application.get_env(:hostctl, :web_server, [])
      |> Keyword.get(:php_fpm_socket_pattern, "/run/php/php{version}-fpm.sock")

    String.replace(pattern, "{version}", php_version || "8.3")
  end
end
