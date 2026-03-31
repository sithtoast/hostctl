defmodule Hostctl.HostingTest do
  use Hostctl.DataCase

  alias Hostctl.Hosting

  import Hostctl.AccountsFixtures

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
end
