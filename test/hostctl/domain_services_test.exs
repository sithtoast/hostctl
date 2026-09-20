defmodule Hostctl.DomainServicesTest do
  use Hostctl.DataCase
  import Hostctl.AccountsFixtures
  alias Hostctl.{Hosting, Settings, WebServer, EmailDelivery, Statistics}
  alias Hostctl.Accounts.Scope
  alias Hostctl.DNS.Zones
  alias Hostctl.Hosting.{Domain, DnsRecord, EmailAccount}
  alias Hostctl.Settings.{DnsTemplateRecord, ServerIpSetting}

  setup do
    scope = user_scope_fixture()
    Settings.load_default_dns_template_records()
    Repo.insert!(%ServerIpSetting{ip_address: "192.0.2.10", external_ip: "192.0.2.10"})
    Repo.insert!(%ServerIpSetting{ip_address: "2001:db8::10"})
    %{scope: scope}
  end

  test "web-only domains omit all standard mail templates but retain unrelated TXT", %{
    scope: scope
  } do
    for attrs <- [
          %{type: "TXT", name: "{{domain}}", value: "site-verification=abc"},
          %{type: "CNAME", name: "s1._domainkey.{{domain}}", value: "dkim.example.net"},
          %{
            type: "SRV",
            name: "_submission._tcp.{{domain}}",
            value: "0 587 mail.{{domain}}",
            priority: 10
          },
          %{type: "CNAME", name: "autodiscover.{{domain}}", value: "mail.{{domain}}"},
          %{type: "A", name: "custom-mx.{{domain}}", value: "192.0.2.10", service: "mail"}
        ] do
      {:ok, _} = Settings.create_dns_template_record(attrs)
    end

    {:ok, domain} = Hosting.create_domain(scope, %{name: "example.com", mail_enabled: false})
    assert domain.web_enabled
    refute domain.mail_enabled
    assert {:ok, updated} = Hosting.update_domain(scope, domain, %{autoindex: true})
    refute updated.mail_enabled
    zone = Hosting.get_dns_zone_for_domain(domain)
    records = Hosting.get_dns_zone_with_records!(domain).dns_records
    assert Enum.any?(records, &(&1.type == "A" && &1.name == "example.com"))
    assert Enum.any?(records, &(&1.value == "site-verification=abc"))
    refute Enum.any?(records, &(&1.type in ["MX", "SRV"]))

    refute Enum.any?(
             records,
             &String.contains?(&1.name, [
               "mail.",
               "_domainkey.",
               "_dmarc.",
               "autodiscover.",
               "custom-mx."
             ])
           )

    refute Enum.any?(records, &String.starts_with?(&1.value, "v=spf1"))

    # DNS management for an external mail service is still allowed explicitly.
    assert {:ok, _} =
             Hosting.create_dns_record(zone, %{
               type: "MX",
               name: "example.com",
               value: "mx.external.test",
               priority: 10
             })

    assert {:error, cs} =
             Hosting.create_email_account(%{domain | mail_enabled: true}, %{
               username: "info",
               password: "good-password-123"
             })

    assert errors_on(cs).username == ["Mail hosting is not enabled for this domain"]
    assert Repo.aggregate(EmailAccount, :count) == 0

    admin =
      user_fixture() |> Ecto.Changeset.change(role: "admin") |> Repo.update!() |> Scope.for_user()

    assert EmailDelivery.list_domains(admin) == []

    assert {:error, "Mail hosting is not enabled for this domain"} =
             EmailDelivery.preview(admin, domain.id)
  end

  test "mail-only and DNS-only domains skip web provisioning and web DNS", %{scope: scope} do
    old = Application.get_env(:hostctl, :web_server)

    Application.put_env(:hostctl, :web_server,
      enabled: true,
      nginx_validate_cmd: ["must-not-run"]
    )

    on_exit(fn -> Application.put_env(:hostctl, :web_server, old) end)

    {:ok, domain} = Hosting.create_domain(scope, %{name: "mail-only.com", web_enabled: false})
    assert :ok = WebServer.sync_domain(%{domain | web_enabled: true})
    records = Hosting.get_dns_zone_with_records!(domain).dns_records
    assert Enum.any?(records, &(&1.type == "MX"))

    refute Enum.any?(
             records,
             &(&1.name in ["mail-only.com", "www.mail-only.com", "ftp.mail-only.com"] &&
                 &1.type in ["A", "AAAA", "CNAME"])
           )

    assert {:error, _} = Hosting.create_subdomain(domain, %{name: "www"})
    refute domain.id in Statistics.enabled_ids()

    {:ok, dns_only} =
      Hosting.create_domain(scope, %{
        name: "dns-only.com",
        web_enabled: false,
        mail_enabled: false,
        apply_dns_template: false
      })

    assert Hosting.get_dns_zone_with_records!(dns_only).dns_records == []

    assert {:error, :web_hosting_disabled, _} =
             Hostctl.CertBot.provision(dns_only, %Hostctl.Hosting.SslCertificate{})
  end

  test "legacy defaults stay enabled and editing other domain settings retains selection", %{
    scope: scope
  } do
    {:ok, domain} = Hosting.create_domain(scope, %{name: "legacy.com"})
    assert domain.web_enabled && domain.mail_enabled
    assert Enum.any?(Hosting.get_dns_zone_with_records!(domain).dns_records, &(&1.type == "MX"))
    assert {:ok, updated} = Hosting.update_domain(scope, domain, %{autoindex: true})
    assert updated.web_enabled && updated.mail_enabled
    assert {:error, cs} = Hosting.update_domain(scope, domain, %{mail_enabled: false})
    assert errors_on(cs).mail_enabled == ["is selected when adding a domain"]
    assert Repo.get!(Domain, domain.id).mail_enabled
  end

  for provider <- ["cloudflare", "digitalocean"] do
    test "#{provider} linking/sync leaves external mail records intact", %{scope: scope} do
      provider = unquote(provider)

      key =
        if provider == "cloudflare",
          do: :cloudflare_request_options,
          else: :digitalocean_request_options

      old = Application.get_env(:hostctl, key)
      Application.put_env(:hostctl, key, plug: {Req.Test, __MODULE__})

      on_exit(fn ->
        if old,
          do: Application.put_env(:hostctl, key, old),
          else: Application.delete_env(:hostctl, key)
      end)

      state = start_supervised!({Agent, fn -> [] end})

      # Focus this check on web/mail records, without unrelated authoritative NS handling.
      Repo.delete_all(from t in DnsTemplateRecord, where: t.type == "NS")

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = if raw == "", do: nil, else: Jason.decode!(raw)
        Agent.update(state, &[{conn.method, body} | &1])

        external_cf = [
          %{
            "id" => "external-mx",
            "type" => "MX",
            "name" => "example.com",
            "content" => "mx.external.test",
            "priority" => 10,
            "ttl" => 300
          }
        ]

        external_do = [
          %{
            "id" => 99,
            "type" => "MX",
            "name" => "@",
            "data" => "mx.external.test",
            "priority" => 10,
            "ttl" => 300
          }
        ]

        response =
          case {provider, conn.method, conn.request_path} do
            {"cloudflare", "GET", "/client/v4/zones"} ->
              %{"success" => true, "result" => [%{"id" => "zone"}]}

            {"cloudflare", "GET", _} ->
              %{"success" => true, "result" => external_cf}

            {"cloudflare", "POST", _} ->
              %{
                "success" => true,
                "result" => %{"id" => "new-#{System.unique_integer([:positive])}"}
              }

            {"digitalocean", "GET", "/v2/domains/example.com"} ->
              %{"domain" => %{"name" => "example.com"}}

            {"digitalocean", "GET", _} ->
              %{"domain_records" => external_do}

            {"digitalocean", "POST", _} ->
              %{"domain_record" => Map.put(body, "id", System.unique_integer([:positive]))}

            _ ->
              flunk("Unexpected DNS operation #{conn.method}")
          end

        Req.Test.json(conn, response)
      end)

      {:ok, domain} = Hosting.create_domain(scope, %{name: "example.com", mail_enabled: false})
      assert Agent.get(state, & &1) == []
      zone = Hosting.get_dns_zone_for_domain(domain)

      {:ok, zone} =
        Zones.save_provider(scope, zone.id, %{
          provider: provider,
          cloudflare_api_token: "test",
          digitalocean_api_token: "test"
        })

      case provider do
        "cloudflare" ->
          assert {:ok, linked} = Hosting.link_zone_to_cloudflare(zone)
          assert {:ok, %{failed: 0}} = Hosting.sync_zone_to_cloudflare(linked)

        "digitalocean" ->
          assert {:ok, _} = Zones.link(scope, zone.id)
          assert {:ok, %{failed: 0}} = Zones.sync(scope, zone.id)
      end

      writes = Agent.get(state, &Enum.filter(&1, fn {method, _} -> method != "GET" end))
      assert writes != []

      for {method, record} <- writes do
        assert method == "POST"
        assert record["type"] in ["A", "AAAA", "CNAME"]
        refute String.contains?(record["name"], "mail")
      end

      refute Repo.exists?(
               from r in DnsRecord, where: r.dns_zone_id == ^zone.id and r.type == "MX"
             )
    end
  end
end
