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
  alias Hostctl.Hosting.DomainS3Backend

  @doc "Returns the filename (not the full path) for a domain's Nginx vhost config."
  def config_filename(%Domain{name: name}), do: "#{name}.conf"

  @doc """
  Generates a complete Nginx vhost config for the given domain and its active
  subdomains. Pass the domain's `SslCertificate` record (or nil) to control
  whether SSL server blocks are included. Pass a list of `DomainS3Backend`
  records to proxy some or all requests to S3-compatible storage.

  Each backend's scope is determined by its `subdomain` and `url_path` fields:
  - `subdomain: "", url_path: ""` — whole-domain S3 (replaces filesystem vhost)
  - `subdomain: "cdn", url_path: ""` — whole-subdomain S3
  - `subdomain: "", url_path: "/assets"` — URL-path S3 within main domain vhost
  - `subdomain: "cdn", url_path: "/files"` — URL-path S3 within subdomain vhost
  """
  def generate_config(
        %Domain{} = domain,
        subdomains \\ [],
        ssl_cert \\ nil,
        proxies \\ [],
        s3_backends \\ []
      ) do
    if domain.status == "suspended" do
      suspended_config(domain)
    else
      active_config(domain, subdomains, ssl_cert, proxies, s3_backends)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp active_config(%Domain{} = domain, subdomains, ssl_cert, proxies, s3_backends) do
    doc_root = domain.document_root || "/var/www/#{domain.name}/httpdocs"
    php_socket = php_fpm_socket(domain.php_version)
    use_ssl = ssl_active?(domain, ssl_cert)

    # Partition enabled backends by scope.
    enabled = Enum.filter(s3_backends, & &1.enabled)
    whole_domain_backend = Enum.find(enabled, &(&1.subdomain == "" && &1.url_path == ""))
    domain_path_backends = Enum.filter(enabled, &(&1.subdomain == "" && &1.url_path != ""))

    subdomain_backend_map =
      enabled
      |> Enum.filter(&(&1.subdomain != ""))
      |> Enum.group_by(& &1.subdomain)

    main =
      if whole_domain_backend do
        s3_vhost_block(
          domain.name,
          "#{domain.name} www.#{domain.name}",
          whole_domain_backend,
          use_ssl,
          ssl_cert
        )
      else
        vhost_block(
          domain.name,
          "#{domain.name} www.#{domain.name}",
          doc_root,
          php_socket,
          use_ssl,
          ssl_cert,
          proxies,
          domain_path_backends,
          domain.autoindex
        )
      end

    # Subdomains that have DB records.
    active_subs = Enum.filter(subdomains, &(&1.status == "active"))
    active_sub_names = Enum.map(active_subs, & &1.name)

    # Subdomain names that only exist as S3 backend entries (no DB Subdomain record).
    extra_sub_names = Map.keys(subdomain_backend_map) -- active_sub_names

    active_sub_blocks =
      Enum.map(active_subs, fn sub ->
        sub_root = sub.document_root || "/var/www/#{domain.name}/#{sub.name}.#{domain.name}"
        backends_for_sub = Map.get(subdomain_backend_map, sub.name, [])
        whole_sub_backend = Enum.find(backends_for_sub, &(&1.url_path == ""))
        path_backends_for_sub = Enum.filter(backends_for_sub, &(&1.url_path != ""))

        if whole_sub_backend do
          s3_vhost_block(
            "#{sub.name}.#{domain.name}",
            "#{sub.name}.#{domain.name}",
            whole_sub_backend,
            false,
            nil
          )
        else
          vhost_block(
            "#{sub.name}.#{domain.name}",
            "#{sub.name}.#{domain.name}",
            sub_root,
            php_socket,
            false,
            nil,
            [],
            path_backends_for_sub,
            sub.autoindex
          )
        end
      end)

    # S3-only vhosts for subdomains that have no DB Subdomain record.
    extra_sub_blocks =
      Enum.map(extra_sub_names, fn sub_name ->
        backends_for_sub = Map.get(subdomain_backend_map, sub_name, [])
        whole_sub_backend = Enum.find(backends_for_sub, &(&1.url_path == ""))
        path_backends_for_sub = Enum.filter(backends_for_sub, &(&1.url_path != ""))

        if whole_sub_backend do
          s3_vhost_block(
            "#{sub_name}.#{domain.name}",
            "#{sub_name}.#{domain.name}",
            whole_sub_backend,
            false,
            nil
          )
        else
          # No filesystem document root for this subdomain – generate a basic
          # vhost with the S3 path location blocks anyway.
          sub_root = "/var/www/#{domain.name}/#{sub_name}.#{domain.name}"

          vhost_block(
            "#{sub_name}.#{domain.name}",
            "#{sub_name}.#{domain.name}",
            sub_root,
            php_socket,
            false,
            nil,
            [],
            path_backends_for_sub,
            false
          )
        end
      end)

    Enum.join([main | active_sub_blocks ++ extra_sub_blocks], "\n")
  end

  defp vhost_block(
         log_name,
         server_names,
         doc_root,
         php_socket,
         false = _ssl,
         _cert,
         proxies,
         s3_path_backends,
         autoindex
       ) do
    proxy_locations = proxy_location_blocks(proxies)
    s3_locations = s3_location_blocks(s3_path_backends)
    s3_error_handler = s3_path_error_handler(s3_path_backends)
    root_location = root_location_block(autoindex)

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

      #{proxy_locations}

      #{s3_locations}

        location / {
            #{root_location}
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
    #{s3_error_handler}}
    """
  end

  defp vhost_block(
         log_name,
         server_names,
         doc_root,
         php_socket,
         true = _ssl,
         ssl_cert,
         proxies,
         s3_path_backends,
         autoindex
       ) do
    primary = server_names |> String.split(" ") |> hd()
    ssl_cert_path = cert_path(ssl_cert, primary)
    ssl_key_path = key_path(ssl_cert, primary)
    proxy_locations = proxy_location_blocks(proxies)
    s3_locations = s3_location_blocks(s3_path_backends)
    s3_error_handler = s3_path_error_handler(s3_path_backends)
    root_location = root_location_block(autoindex)

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

      #{proxy_locations}

      #{s3_locations}

        location / {
            #{root_location}
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
    #{s3_error_handler}}
    """
  end

  # Returns the `location /` body for a filesystem vhost.
  # When autoindex is enabled, directories without an index file show a listing
  # instead of falling through to PHP. PHP files are still served via the
  # separate `location ~ \.php$` block.
  defp root_location_block(true),
    do: "autoindex on;\n            try_files $uri $uri/ =404;"

  defp root_location_block(_),
    do: "try_files $uri $uri/ /index.php?$query_string;"

  # ---------------------------------------------------------------------------
  # S3 path location blocks (injected into filesystem vhosts)
  # ---------------------------------------------------------------------------

  defp s3_location_blocks([]), do: ""

  defp s3_location_blocks(backends) do
    backends
    |> Enum.map(&s3_location_block/1)
    |> Enum.join("\n")
  end

  # Generates a single `location /path/` block that proxies to S3.
  # Nginx strips the url_path prefix from the request URI because proxy_pass
  # includes a URI component, leaving only the remaining path for the upstream.
  defp s3_location_block(%DomainS3Backend{} = backend) do
    # Ensure the location path ends with a trailing slash so nginx performs
    # prefix-stripping when forwarding to the upstream URI.
    location_path = String.trim_trailing(backend.url_path, "/") <> "/"

    if use_phoenix_proxy?(backend) do
      upstream = phoenix_proxy_url(backend)
      token = s3_proxy_token()

      token_line =
        if token != "",
          do: "\n              proxy_set_header X-S3-Proxy-Token #{token};",
          else: ""

      """
          location ^~ #{location_path} {
              proxy_pass #{upstream};
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto https;#{token_line}
              proxy_intercept_errors on;
              error_page 404 = @s3_path_not_found;
          }
      """
    else
      upstream = s3_upstream_url(backend)
      upstream_host = s3_upstream_host(backend)

      """
          location ^~ #{location_path} {
              proxy_pass #{upstream};
              proxy_set_header Host #{upstream_host};
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_hide_header x-amz-id-2;
              proxy_hide_header x-amz-request-id;
              proxy_hide_header x-amz-meta-server-side-encryption;
              proxy_hide_header x-amz-server-side-encryption;
              proxy_hide_header Set-Cookie;
              proxy_ignore_headers Set-Cookie;
              proxy_intercept_errors on;
              error_page 404 = @s3_path_not_found;
          }
      """
    end
  end

  # Injects a named location handler for S3 404s when any path backends exist.
  defp s3_path_error_handler([]), do: ""

  defp s3_path_error_handler(_backends) do
    """
        location @s3_path_not_found {
            return 404;
        }
    """
  end

  defp proxy_location_blocks([]), do: ""

  defp proxy_location_blocks(proxies) do
    proxies
    |> Enum.filter(& &1.enabled)
    |> Enum.map(fn proxy ->
      path = normalize_proxy_path(proxy.path)
      target = "http://127.0.0.1:#{proxy.upstream_port}/"

      """
        location = #{path} {
            return 301 #{path}/;
        }

        location ^~ #{path}/ {
            proxy_pass #{target};
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
            proxy_connect_timeout 60s;
            proxy_read_timeout 86400s;
            proxy_send_timeout 86400s;
        }
      """
    end)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # S3-backed vhost blocks
  # ---------------------------------------------------------------------------

  defp s3_vhost_block(log_name, server_names, %DomainS3Backend{} = backend, false = _ssl, _cert) do
    if use_phoenix_proxy?(backend) do
      phoenix_proxy_block_http(log_name, server_names, backend)
    else
      s3_direct_block_http(log_name, server_names, backend)
    end
  end

  defp s3_vhost_block(log_name, server_names, %DomainS3Backend{} = backend, true = _ssl, ssl_cert) do
    if use_phoenix_proxy?(backend) do
      phoenix_proxy_block_ssl(log_name, server_names, backend, ssl_cert)
    else
      s3_direct_block_ssl(log_name, server_names, backend, ssl_cert)
    end
  end

  defp has_credentials?(%DomainS3Backend{access_key_id: key}) when is_binary(key) and key != "",
    do: true

  defp has_credentials?(_), do: false

  defp use_phoenix_proxy?(%DomainS3Backend{} = backend),
    do: has_credentials?(backend) || backend.directory_listing

  # Proxies to local Phoenix S3ProxyController (private buckets).
  # The URL uses the backend's DB id so nginx can strip the url_path prefix
  # while the controller still knows exactly which backend to serve from.
  defp phoenix_proxy_block_http(log_name, server_names, backend) do
    upstream = phoenix_proxy_url(backend)
    token = s3_proxy_token()

    token_line =
      if token != "", do: "\n            proxy_set_header X-S3-Proxy-Token #{token};", else: ""

    """
    # #{log_name} — managed by hostctl (S3 backend, private)
    server {
        listen 80;
        listen [::]:80;
        server_name #{server_names};

        access_log /var/log/nginx/#{log_name}.access.log;
        error_log /var/log/nginx/#{log_name}.error.log;

        location / {
            proxy_pass #{upstream};
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;#{token_line}
            proxy_intercept_errors on;
            error_page 404 = @not_found;
        }

        location @not_found {
            return 404;
        }
    }
    """
  end

  defp phoenix_proxy_block_ssl(log_name, server_names, backend, ssl_cert) do
    primary = server_names |> String.split(" ") |> hd()
    ssl_cert_path = cert_path(ssl_cert, primary)
    ssl_key_path = key_path(ssl_cert, primary)
    upstream = phoenix_proxy_url(backend)
    token = s3_proxy_token()

    token_line =
      if token != "", do: "\n            proxy_set_header X-S3-Proxy-Token #{token};", else: ""

    """
    # #{log_name} — managed by hostctl (S3 backend, private)
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

        access_log /var/log/nginx/#{log_name}.access.log;
        error_log /var/log/nginx/#{log_name}.error.log;

        location / {
            proxy_pass #{upstream};
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;#{token_line}
            proxy_intercept_errors on;
            error_page 404 = @not_found;
        }

        location @not_found {
            return 404;
        }
    }
    """
  end

  # Proxies directly to the public S3 endpoint (no credentials)
  defp s3_direct_block_http(log_name, server_names, backend) do
    upstream = s3_upstream_url(backend)
    upstream_host = s3_upstream_host(backend)

    """
    # #{log_name} — managed by hostctl (S3 backend)
    server {
        listen 80;
        listen [::]:80;
        server_name #{server_names};

        access_log /var/log/nginx/#{log_name}.access.log;
        error_log /var/log/nginx/#{log_name}.error.log;

        location / {
            proxy_pass #{upstream};
            proxy_set_header Host #{upstream_host};
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_hide_header x-amz-id-2;
            proxy_hide_header x-amz-request-id;
            proxy_hide_header x-amz-meta-server-side-encryption;
            proxy_hide_header x-amz-server-side-encryption;
            proxy_hide_header Set-Cookie;
            proxy_ignore_headers Set-Cookie;
            proxy_intercept_errors on;
            error_page 404 = @s3_not_found;
        }

        location @s3_not_found {
            return 404;
        }
    }
    """
  end

  defp s3_direct_block_ssl(log_name, server_names, backend, ssl_cert) do
    primary = server_names |> String.split(" ") |> hd()
    ssl_cert_path = cert_path(ssl_cert, primary)
    ssl_key_path = key_path(ssl_cert, primary)
    upstream = s3_upstream_url(backend)
    upstream_host = s3_upstream_host(backend)

    """
    # #{log_name} — managed by hostctl (S3 backend)
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

        access_log /var/log/nginx/#{log_name}.access.log;
        error_log /var/log/nginx/#{log_name}.error.log;

        location / {
            proxy_pass #{upstream};
            proxy_set_header Host #{upstream_host};
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_hide_header x-amz-id-2;
            proxy_hide_header x-amz-request-id;
            proxy_hide_header x-amz-meta-server-side-encryption;
            proxy_hide_header x-amz-server-side-encryption;
            proxy_hide_header Set-Cookie;
            proxy_ignore_headers Set-Cookie;
            proxy_intercept_errors on;
            error_page 404 = @s3_not_found;
        }

        location @s3_not_found {
            return 404;
        }
    }
    """
  end

  # Builds the Phoenix S3 proxy URL using the backend's DB id.
  # Nginx proxies to this URL when the backend has credentials configured.
  # Because the URL path includes the backend id, nginx can strip any url_path
  # prefix via the proxy_pass URI rewrite and the controller resolves the
  # correct backend by id.
  defp phoenix_proxy_url(%DomainS3Backend{id: id}) do
    port =
      Application.get_env(:hostctl, HostctlWeb.Endpoint)
      |> Keyword.get(:http, [])
      |> Keyword.get(:port, 4000)

    "http://127.0.0.1:#{port}/_s3_proxy/#{id}/"
  end

  defp s3_proxy_token do
    Application.get_env(:hostctl, :s3_proxy_token, "")
  end

  # Builds the proxy_pass target URL: endpoint/bucket/prefix/
  defp s3_upstream_url(%DomainS3Backend{endpoint_url: ep, bucket: bucket, path_prefix: prefix}) do
    base = "#{ep}/#{bucket}"

    if prefix && prefix != "" do
      "#{base}/#{prefix}/"
    else
      "#{base}/"
    end
  end

  # Extracts the Host header value from the endpoint URL (hostname only)
  defp s3_upstream_host(%DomainS3Backend{endpoint_url: ep}) do
    ep |> URI.parse() |> Map.get(:host, ep)
  end

  defp normalize_proxy_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    normalized =
      if String.starts_with?(trimmed, "/") do
        trimmed
      else
        "/" <> trimmed
      end

    if normalized != "/" do
      String.trim_trailing(normalized, "/")
    else
      normalized
    end
  end

  defp normalize_proxy_path(_), do: "/"

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
