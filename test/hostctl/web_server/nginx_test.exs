defmodule Hostctl.WebServer.NginxTest do
  use ExUnit.Case, async: true

  alias Hostctl.Hosting.Domain
  alias Hostctl.Hosting.DomainProxy
  alias Hostctl.Hosting.DomainS3Backend
  alias Hostctl.Hosting.Subdomain
  alias Hostctl.Hosting.SslCertificate
  alias Hostctl.WebServer.Nginx

  for {ssl, allow_http, expected_roots} <- [{false, false, 1}, {true, false, 1}, {true, true, 2}] do
    test "root Docker proxy with SSL=#{ssl}, allow_http=#{allow_http}" do
      config =
        Nginx.generate_config(
          %Domain{
            name: "example.com",
            ssl_enabled: unquote(ssl),
            allow_http_with_ssl: unquote(allow_http),
            autoindex: true
          },
          [],
          %SslCertificate{status: "active", cert_type: "custom"},
          [
            %DomainProxy{path: "/", upstream_port: 3000},
            %DomainProxy{path: "/api", upstream_port: 4000}
          ]
        )

      assert length(Regex.scan(~r/location \^~ \/ \{/, config)) == unquote(expected_roots)
      assert config =~ "proxy_pass http://127.0.0.1:3000/;"
      assert config =~ "location ^~ /api/ {"
      assert config =~ "location = /api {"
      assert config =~ "proxy_pass http://127.0.0.1:4000/;"
      assert config =~ "proxy_set_header Upgrade $http_upgrade;"
      assert config =~ "proxy_set_header X-Forwarded-Proto $scheme;"
      refute config =~ "location / {"
      refute config =~ "location = / {"
      refute config =~ "location ^~ //"
      refute config =~ "try_files"
      refute config =~ "autoindex on;"

      assert config =~ "return 301 https://$host$request_uri;" ==
               (unquote(ssl) and not unquote(allow_http))
    end
  end

  test "disabled root proxy preserves filesystem serving and subpath proxies" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com", autoindex: true},
        [],
        nil,
        [
          %DomainProxy{path: "/", upstream_port: 3000, enabled: false},
          %DomainProxy{path: "/app", upstream_port: 4000}
        ]
      )

    assert config =~ "location / {"
    assert config =~ "autoindex on;"
    assert config =~ "location ^~ /app/ {"
    refute config =~ "127.0.0.1:3000"
  end

  test "root proxy does not replace subdomain filesystem serving" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com"},
        [%Subdomain{name: "blog", status: "active"}],
        nil,
        [%DomainProxy{path: "/", upstream_port: 3000}]
      )

    assert length(Regex.scan(~r/proxy_pass http:\/\/127.0.0.1:3000\//, config)) == 1
    assert config =~ "server_name blog.example.com;"
    assert config =~ "try_files $uri $uri/ /index.php?$query_string;"
  end

  test "redirects HTTP to HTTPS by default when SSL is active" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com", ssl_enabled: true, allow_http_with_ssl: false},
        [],
        %SslCertificate{status: "active", cert_type: "custom"}
      )

    assert config =~ "return 301 https://$host$request_uri;"
    assert config =~ "listen 443 ssl http2;"
  end

  test "keeps HTTP enabled when configured alongside active SSL" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com", ssl_enabled: true, allow_http_with_ssl: true},
        [],
        %SslCertificate{status: "active", cert_type: "custom"}
      )

    refute config =~ "return 301 https://$host$request_uri;"
    assert config =~ "listen 80;"
    assert config =~ "listen 443 ssl http2;"
    assert length(Regex.scan(~r/server_name example\.com www\.example\.com;/, config)) == 2
  end

  test "emits ssl for whole-subdomain s3 backends" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com", ssl_enabled: true, allow_http_with_ssl: true},
        [],
        %SslCertificate{
          status: "active",
          cert_type: "custom",
          covers_wildcard_subdomains: true
        },
        [],
        [
          %DomainS3Backend{
            id: 4,
            subdomain: "static",
            endpoint_url: "https://s3.example.com",
            bucket: "static-assets",
            access_key_id: "key",
            secret_access_key: "secret"
          }
        ]
      )

    assert config =~ "server_name static.example.com;"
    assert config =~ "listen 443 ssl http2;"
    assert config =~ "proxy_pass http://127.0.0.1:4000/_s3_proxy/4/;"
    assert config =~ "ssl_certificate /etc/ssl/hostctl/example.com/fullchain.pem;"
  end

  test "emits ssl for filesystem subdomains when wildcard coverage is enabled" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com", ssl_enabled: true, allow_http_with_ssl: false},
        [%Subdomain{name: "blog", status: "active"}],
        %SslCertificate{
          status: "active",
          cert_type: "custom",
          covers_wildcard_subdomains: true
        }
      )

    assert config =~ "server_name blog.example.com;"
    assert length(Regex.scan(~r/listen 443 ssl http2;/, config)) == 2
    assert config =~ "ssl_certificate /etc/ssl/hostctl/example.com/fullchain.pem;"
  end

  test "does not emit ssl for filesystem subdomains without wildcard coverage" do
    config =
      Nginx.generate_config(
        %Domain{name: "example.com", ssl_enabled: true, allow_http_with_ssl: false},
        [%Subdomain{name: "blog", status: "active"}],
        %SslCertificate{status: "active", cert_type: "custom", covers_wildcard_subdomains: false}
      )

    assert config =~ "server_name blog.example.com;"
    assert length(Regex.scan(~r/listen 443 ssl http2;/, config)) == 1
  end
end
