defmodule Hostctl.HostingTest do
  use Hostctl.DataCase

  alias Hostctl.Hosting
  alias Hostctl.Hosting.DbUser

  import Hostctl.AccountsFixtures

  defp create_database_fixture(scope, attrs) do
    {:ok, domain} =
      Hosting.create_domain(scope, %{
        name: attrs[:domain_name] || "db-example.com",
        apply_dns_template: false
      })

    {:ok, database} =
      Hosting.create_database(domain, %{
        name: attrs[:database_name] || "app_db",
        db_type: attrs[:db_type] || "mysql"
      })

    database
  end

  describe "import_cloudflare_zone_records/2" do
    test "imports supported Cloudflare records into the local zone" do
      scope = user_scope_fixture()

      assert {:ok, domain} =
               Hosting.create_domain(scope, %{
                 name: "example.com",
                 apply_dns_template: false
               })

      zone = Hosting.get_dns_zone_with_records!(domain)

      cloudflare_records = [
        %{
          "id" => "cf-a-root",
          "type" => "A",
          "name" => "example.com",
          "content" => "203.0.113.10",
          "ttl" => 120,
          "proxied" => true
        },
        %{
          "id" => "cf-mx-root",
          "type" => "MX",
          "name" => "example.com",
          "content" => "mail.example.com",
          "ttl" => 3600,
          "priority" => 10
        },
        %{
          "id" => "cf-unsupported",
          "type" => "HTTPS",
          "name" => "example.com",
          "content" => "svc.example.com",
          "ttl" => 3600
        }
      ]

      assert {:ok, %{imported: 2, updated: 0, skipped: 1}} =
               Hosting.import_cloudflare_zone_records(zone, cloudflare_records)

      records = Hosting.get_dns_zone_with_records!(domain).dns_records

      assert Enum.any?(records, fn record ->
               record.cloudflare_record_id == "cf-a-root" and record.type == "A" and
                 record.name == "example.com" and record.value == "203.0.113.10" and
                 record.ttl == 120
             end)

      assert Enum.any?(records, fn record ->
               record.cloudflare_record_id == "cf-mx-root" and record.type == "MX" and
                 record.priority == 10
             end)
    end

    test "updates existing local records instead of duplicating them" do
      scope = user_scope_fixture()

      assert {:ok, domain} =
               Hosting.create_domain(scope, %{
                 name: "example.net",
                 apply_dns_template: false
               })

      zone = Hosting.get_dns_zone_with_records!(domain)

      assert {:ok, _record} =
               Hosting.create_dns_record(zone, %{
                 type: "A",
                 name: "example.net",
                 value: "192.0.2.10",
                 ttl: 3600
               })

      cloudflare_records = [
        %{
          "id" => "cf-existing-a",
          "type" => "A",
          "name" => "example.net",
          "content" => "192.0.2.10",
          "ttl" => 600
        }
      ]

      assert {:ok, %{imported: 0, updated: 1, skipped: 0}} =
               Hosting.import_cloudflare_zone_records(zone, cloudflare_records)

      [record] = Hosting.get_dns_zone_with_records!(domain).dns_records

      assert record.cloudflare_record_id == "cf-existing-a"
      assert record.ttl == 600
    end
  end

  describe "domain proxies" do
    test "creates a domain proxy and normalizes path" do
      scope = user_scope_fixture()

      assert {:ok, domain} =
               Hosting.create_domain(scope, %{
                 name: "proxy-example.com",
                 apply_dns_template: false
               })

      assert {:ok, proxy} =
               Hosting.create_domain_proxy(%{
                 domain_id: domain.id,
                 path: "/app/",
                 container_name: "web-app",
                 upstream_port: 3000,
                 enabled: true
               })

      assert proxy.path == "/app"

      proxies = Hosting.list_domain_proxies(domain)
      assert length(proxies) == 1
      assert hd(proxies).container_name == "web-app"
    end

    test "rejects duplicate path for the same domain" do
      scope = user_scope_fixture()

      assert {:ok, domain} =
               Hosting.create_domain(scope, %{
                 name: "proxy-duplicate.com",
                 apply_dns_template: false
               })

      assert {:ok, _proxy} =
               Hosting.create_domain_proxy(%{
                 domain_id: domain.id,
                 path: "/api",
                 container_name: "api-1",
                 upstream_port: 4000,
                 enabled: true
               })

      assert {:error, changeset} =
               Hosting.create_domain_proxy(%{
                 domain_id: domain.id,
                 path: "/api",
                 container_name: "api-2",
                 upstream_port: 4001,
                 enabled: true
               })

      assert %{path: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "ssl certificates" do
    test "can replace an existing certificate for the same domain" do
      scope = user_scope_fixture()

      assert {:ok, domain} =
               Hosting.create_domain(scope, %{
                 name: "ssl-reissue-example.com",
                 apply_dns_template: false
               })

      assert {:ok, first_cert} =
               Hosting.create_ssl_certificate(domain, %{
                 cert_type: "custom",
                 status: "active",
                 certificate: "first-cert",
                 private_key: "first-key",
                 email: "first@example.com"
               })

      assert {:ok, replacement_cert} =
               Hosting.create_ssl_certificate(
                 domain,
                 %{
                   cert_type: "lets_encrypt",
                   status: "pending",
                   email: "second@example.com",
                   covers_wildcard_subdomains: true
                 },
                 replace_existing: true
               )

      assert replacement_cert.id != first_cert.id
      assert replacement_cert.email == "second@example.com"
      assert replacement_cert.covers_wildcard_subdomains == true
      assert replacement_cert.cert_type == "lets_encrypt"
      assert Hosting.get_ssl_certificate(domain).id == replacement_cert.id
    end
  end

  describe "database users" do
    test "defaults mysql users to localhost-only access" do
      scope = user_scope_fixture()

      database =
        create_database_fixture(scope, domain_name: "db-local.test", database_name: "local_db")

      assert {:ok, db_user} =
               Hosting.create_db_user(database, %{
                 username: "local_user",
                 password: "supersecret1"
               })

      assert db_user.access_host == "localhost"
    end

    test "stores a specific remote mysql host when requested" do
      scope = user_scope_fixture()

      database =
        create_database_fixture(scope, domain_name: "db-remote.test", database_name: "remote_db")

      assert {:ok, db_user} =
               Hosting.create_db_user(database, %{
                 username: "remote_user",
                 password: "supersecret1",
                 access_mode: "remote",
                 access_host: "198.51.100.25"
               })

      assert db_user.access_host == "198.51.100.25"
    end

    test "rejects wildcard remote mysql access hosts" do
      changeset =
        DbUser.changeset(%DbUser{}, %{
          username: "remote_user",
          password: "supersecret1",
          access_mode: "remote",
          access_host: "%"
        })

      refute changeset.valid?
      assert "must be a valid IP address or hostname" in errors_on(changeset).access_host
    end

    test "updates mysql user to a specific remote host" do
      scope = user_scope_fixture()

      database =
        create_database_fixture(scope,
          domain_name: "db-edit-host.test",
          database_name: "edit_host_db"
        )

      assert {:ok, db_user} =
               Hosting.create_db_user(database, %{
                 username: "edit_user",
                 password: "supersecret1"
               })

      assert {:ok, updated_user} =
               Hosting.update_db_user(db_user, database, %{
                 access_mode: "remote",
                 access_host: "db-client.example.com",
                 password: "supersecret2"
               })

      assert updated_user.access_host == "db-client.example.com"
      assert updated_user.hashed_password != db_user.hashed_password
    end

    test "updates mysql user back to localhost-only access" do
      scope = user_scope_fixture()

      database =
        create_database_fixture(
          scope,
          domain_name: "db-edit-local.test",
          database_name: "edit_local_db"
        )

      assert {:ok, db_user} =
               Hosting.create_db_user(database, %{
                 username: "edit_local_user",
                 password: "supersecret1",
                 access_mode: "remote",
                 access_host: "198.51.100.20"
               })

      assert {:ok, updated_user} =
               Hosting.update_db_user(db_user, database, %{
                 access_mode: "localhost",
                 password: "supersecret2"
               })

      assert updated_user.access_host == "localhost"
    end
  end
end
