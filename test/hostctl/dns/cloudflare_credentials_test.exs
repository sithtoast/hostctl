defmodule Hostctl.DNS.CloudflareCredentialsTest do
  use Hostctl.DataCase
  import Hostctl.AccountsFixtures
  alias Hostctl.{Hosting, Settings}
  alias Hostctl.DNS.Zones
  alias Hostctl.Hosting.{Domain, DnsZone, DnsRecord, SslCertificate}

  setup do
    previous = Application.get_env(:hostctl, :cloudflare_request_options)
    Application.put_env(:hostctl, :cloudflare_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :cloudflare_request_options, previous),
        else: Application.delete_env(:hostctl, :cloudflare_request_options)
    end)

    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(parent, {:request, conn.method, Plug.Conn.get_req_header(conn, "authorization")})

      result =
        case {conn.method, conn.request_path} do
          {"GET", "/client/v4/zones"} -> [%{"id" => "owned-zone"}]
          {"GET", _} -> []
          {"POST", _} -> %{"id" => "owned-record"}
          _ -> %{}
        end

      Req.Test.json(conn, %{"success" => true, "result" => result})
    end)

    user = user_fixture() |> Ecto.Changeset.change(role: "reseller") |> Repo.update!()
    scope = Hostctl.Accounts.Scope.for_user(user)
    domain = Repo.insert!(%Domain{name: "example.com", user_id: user.id})
    zone = Repo.insert!(%DnsZone{domain_id: domain.id})

    {:ok, _} =
      Settings.save_dns_provider_setting(%{
        provider: "local",
        cloudflare_api_token: "panel-token"
      })

    %{scope: scope, domain: domain, zone: zone}
  end

  test "reseller token is encrypted, masked, preserved on blank, and explicitly removable", ctx do
    {:ok, zone} =
      Zones.save_provider(ctx.scope, ctx.zone.id, %{
        provider: "cloudflare",
        cloudflare_api_token: "domain-token"
      })

    [[stored]] =
      Repo.query!("SELECT cloudflare_api_token FROM dns_zones WHERE id = $1", [zone.id]).rows

    refute stored == "domain-token"
    assert {:ok, "domain-token"} = Hostctl.EncryptedField.load(stored)
    refute inspect(zone) =~ "domain-token"
    assert Settings.dns_setting_for_domain(ctx.domain).cloudflare_api_token == "domain-token"
    assert Settings.cloudflare_enabled_for_domain?(ctx.domain)
    {:ok, zone} = Zones.save_provider(ctx.scope, zone.id, %{cloudflare_api_token: ""})
    assert zone.cloudflare_api_token == "domain-token"
    {:ok, zone} = Zones.save_provider(ctx.scope, zone.id, %{clear_cloudflare_token: true})
    assert Settings.dns_setting_for_zone(zone).cloudflare_api_token == "panel-token"
    refute_received {:request, _, _}
  end

  test "link, read, create, update, delete and sync use domain token with a local panel default",
       ctx do
    {:ok, zone} =
      Zones.save_provider(ctx.scope, ctx.zone.id, %{
        provider: "cloudflare",
        cloudflare_api_token: "domain-token"
      })

    assert {:ok, :readable} = Zones.check_cloudflare(ctx.scope, zone.id)
    assert_receive {:request, "GET", ["Bearer domain-token"]}
    assert_receive {:request, "GET", ["Bearer domain-token"]}
    assert {:ok, zone} = Hosting.link_zone_to_cloudflare(zone)
    assert_receive {:request, "GET", ["Bearer domain-token"]}
    assert_receive {:request, "GET", ["Bearer domain-token"]}
    assert {:ok, []} = Hosting.list_cloudflare_zone_records(zone)
    assert_receive {:request, "GET", ["Bearer domain-token"]}

    assert {:ok, record} =
             Hosting.create_dns_record(zone, %{type: "A", name: "example.com", value: "192.0.2.1"})

    assert_receive {:request, "POST", ["Bearer domain-token"]}
    assert {:ok, _} = Hosting.update_dns_record(record, %{value: "192.0.2.2"})
    assert_receive {:request, "PATCH", ["Bearer domain-token"]}
    assert {:ok, %{synced: 1, failed: 0}} = Hosting.sync_zone_to_cloudflare(zone)
    assert_receive {:request, "GET", ["Bearer domain-token"]}
    assert_receive {:request, "POST", ["Bearer domain-token"]}
    assert {:ok, _} = Hosting.delete_dns_record(record)
    assert_receive {:request, "DELETE", ["Bearer domain-token"]}
    refute_received {:request, _, ["Bearer panel-token"]}
  end

  test "rotating a domain token retires links even for callers holding an old zone", ctx do
    {:ok, zone} =
      Zones.save_provider(ctx.scope, ctx.zone.id, %{
        provider: "cloudflare",
        cloudflare_api_token: "old"
      })

    {:ok, zone} = Hosting.update_dns_zone(zone, %{cloudflare_zone_id: "old-zone"})

    Repo.insert!(%DnsRecord{
      dns_zone_id: zone.id,
      type: "A",
      name: "@",
      value: "192.0.2.1",
      cloudflare_record_id: "old-id"
    })

    {:ok, fresh} = Zones.save_provider(ctx.scope, zone.id, %{cloudflare_api_token: "new"})
    refute fresh.cloudflare_zone_id
    refute Repo.one(from r in DnsRecord, select: r.cloudflare_record_id)
    assert {:error, :not_linked} = Hosting.sync_zone_to_cloudflare(zone)
    assert {:error, :not_linked} = Hosting.list_cloudflare_zone_records(zone)
    refute_received {:request, _, _}
  end

  test "panel rotation unlinks inherited credentials but retains customer tokens", ctx do
    {:ok, _} = Hosting.update_dns_zone(ctx.zone, %{cloudflare_zone_id: "panel-zone"})
    {:ok, _} = Settings.save_dns_provider_setting(%{cloudflare_api_token: "new-panel"})
    refute Repo.get!(DnsZone, ctx.zone.id).cloudflare_zone_id

    {:ok, zone} =
      Zones.save_provider(ctx.scope, ctx.zone.id, %{
        provider: "cloudflare",
        cloudflare_api_token: "own"
      })

    {:ok, _} = Hosting.update_dns_zone(zone, %{cloudflare_zone_id: "own-zone"})
    {:ok, _} = Settings.save_dns_provider_setting(%{cloudflare_api_token: "another-panel"})
    assert Repo.get!(DnsZone, zone.id).cloudflare_zone_id == "own-zone"
    assert Settings.dns_setting_for_domain(ctx.domain).cloudflare_api_token == "own"
    refute_received {:request, _, _}
  end

  test "unrelated accounts cannot set, check or unlink another domain's Cloudflare token", ctx do
    foreign = Hostctl.Accounts.Scope.for_user(user_fixture())

    assert_raise Ecto.NoResultsError, fn ->
      Zones.save_provider(foreign, ctx.zone.id, %{cloudflare_api_token: "injected"})
    end

    assert_raise Ecto.NoResultsError, fn -> Zones.check_cloudflare(foreign, ctx.zone.id) end
    assert_raise Ecto.NoResultsError, fn -> Zones.unlink_cloudflare(foreign, ctx.zone.id) end
    refute_received {:request, _, _}
  end

  test "DNS-01 passes the domain token to an offline certbot stub and cleans up credentials",
       ctx do
    {:ok, _} =
      Zones.save_provider(ctx.scope, ctx.zone.id, %{
        provider: "cloudflare",
        cloudflare_api_token: "domain-token"
      })

    root = Path.join(System.tmp_dir!(), "hostctl-cf-cert-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    executable = Path.join(root, "certbot-stub")

    File.write!(executable, """
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--dns-cloudflare-credentials" ]; then
        cp "$2" '#{root}/captured'
        printf '%s' "$2" > '#{root}/credential-path'
      fi
      shift
    done
    echo 'Offline certbot stub; no certificate requested'
    exit 1
    """)

    File.chmod!(executable, 0o700)
    previous = Application.get_env(:hostctl, :certbot)

    Application.put_env(:hostctl, :certbot,
      enabled: true,
      certbot_cmd: executable,
      letsencrypt_dir: root
    )

    on_exit(fn ->
      Application.put_env(:hostctl, :certbot, previous)
      File.rm_rf!(root)
    end)

    assert {:error, {:certbot_failed, 1, _}, _} =
             Hostctl.CertBot.provision(ctx.domain, %SslCertificate{
               cert_type: "lets_encrypt",
               covers_wildcard_subdomains: true
             })

    assert File.read!(Path.join(root, "captured")) == "dns_cloudflare_api_token = domain-token\n"
    refute File.exists?(File.read!(Path.join(root, "credential-path")))
  end
end
