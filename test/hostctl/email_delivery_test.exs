defmodule Hostctl.EmailDeliveryTest do
  use Hostctl.DataCase
  import Hostctl.AccountsFixtures
  alias Hostctl.EmailDelivery
  alias Hostctl.EmailDelivery.{Plan, SPF, Setting, DNS}
  alias Hostctl.Hosting.{Domain, DnsZone}
  alias Hostctl.Accounts.Scope
  alias Hostctl.EmailDelivery.TestProvider

  setup do
    start_supervised!(%{
      id: TestProvider,
      start:
        {Agent, :start_link,
         [
           fn -> %{records: [], lookups: %{}, writes: [], fail_after: nil} end,
           [name: TestProvider]
         ]}
    })

    for {key, value} <- [
          email_delivery_cloudflare: TestProvider,
          email_delivery_dns: TestProvider
        ] do
      previous = Application.get_env(:hostctl, key)
      Application.put_env(:hostctl, key, value)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:hostctl, key, previous),
          else: Application.delete_env(:hostctl, key)
      end)
    end

    scope = Scope.for_user(admin_user_fixture())
    domain = Repo.insert!(%Domain{name: "example.com", user_id: scope.user.id})
    Repo.insert!(%DnsZone{domain_id: domain.id})

    setting = %Setting{
      domain_id: domain.id,
      domain: domain,
      ipv4: "203.0.113.10",
      hostname: "mail.example.com",
      selector: "hc0123456789abcdef",
      public_key: String.duplicate("A", 80)
    }

    %{scope: scope, domain: domain, setting: setting}
  end

  test "preserves existing SPF senders, unrelated TXT, MX and DMARC enforcement", %{
    setting: setting
  } do
    records = [
      rr("TXT", "example.com", "google-site-verification=keep"),
      rr("TXT", "example.com", "v=spf1 ip4:192.0.2.1 -all"),
      rr("TXT", "_dmarc.example.com", "v=DMARC1; p=reject; adkim=s"),
      rr("MX", "example.com", "inbound.other.example")
    ]

    rows = Plan.build(setting, :direct, records)
    spf = Enum.find(rows, &(&1.label == "SPF"))
    assert spf.value == "v=spf1 ip4:192.0.2.1 ip4:203.0.113.10 -all"
    assert spf.action == :update
    assert spf.before.value == "v=spf1 ip4:192.0.2.1 -all"
    assert Enum.find(rows, &(&1.label == "DMARC")).action == :keep
    refute Enum.any?(rows, &(&1.type == "MX"))
  end

  test "duplicate SPF and CNAME conflicts block writes", %{setting: setting} do
    records = [
      rr("TXT", "example.com", "v=spf1 ip4:192.0.2.1 -all"),
      rr("TXT", "example.com", "v=spf1 ~all"),
      rr("CNAME", "mail.example.com", "other.example")
    ]

    rows = Plan.build(setting, :direct, records)
    assert Enum.find(rows, &(&1.label == "SPF")).action == :blocked
    assert Enum.find(rows, &(&1.label == "Mail hostname")).action == :blocked

    assert {:error, _} =
             Plan.merge_spf([%{value: "v=spf1 redirect=other.example"}], ["ip4:203.0.113.10"])
  end

  test "relay uses provider include and DKIM and no direct IP", %{setting: setting} do
    setting = %{
      setting
      | spf_include: "mailgun.org",
        dkim_records: "s1._domainkey.example.com CNAME s1.provider.example"
    }

    rows = Plan.build(setting, :relay, [])
    assert Enum.find(rows, &(&1.label == "SPF")).value == "v=spf1 include:mailgun.org ~all"
    assert Enum.find(rows, &(&1.label == "DKIM")).type == "CNAME"
    refute Enum.any?(rows, &(&1.type in ["A", "AAAA"]))
  end

  test "DKIM rejects off-domain names, private material and duplicates" do
    assert {:error, _} =
             Plan.parse_dkim("s1._domainkey.attacker.com CNAME provider.example", "example.com")

    assert {:error, _} =
             Plan.parse_dkim(
               "s1._domainkey.example.com TXT -----BEGIN PRIVATE KEY-----",
               "example.com"
             )

    assert {:error, _} =
             Plan.parse_dkim(
               String.duplicate("s1._domainkey.example.com CNAME provider.example\n", 2),
               "example.com"
             )
  end

  test "recursive SPF budget catches loops, missing policies and too many lookups" do
    lookup = fn _, _ -> {:ok, ["v=spf1 include:loop.example ~all"]} end
    assert {:error, _} = SPF.validate("v=spf1 include:loop.example ~all", lookup)

    assert {:error, _} =
             SPF.validate("v=spf1 include:missing.example ~all", fn _, _ -> {:ok, []} end)

    assert {:error, _} = SPF.validate("v=spf1 " <> String.duplicate("mx ", 11) <> "~all", lookup)

    assert :ok =
             SPF.validate("v=spf1 include:sender.example ~all", fn _, _ ->
               {:ok, ["v=spf1 ip4:192.0.2.1 ~all"]}
             end)
  end

  test "DNS TXT chunks and IPv6 PTR names are normalized" do
    assert DNS.txt(~s("v=DKIM1; " "p=abc")) == "v=DKIM1; p=abc"
    assert DNS.reverse("192.0.2.1") == "1.2.0.192.in-addr.arpa"
    assert String.ends_with?(DNS.reverse("2001:db8::1"), "8.b.d.0.1.0.0.2.ip6.arpa")
  end

  test "fresh Cloudflare publication is idempotent and detects stale previews", %{
    scope: scope,
    setting: setting
  } do
    configure(scope, setting)
    {:ok, plan} = EmailDelivery.preview(scope, setting.domain_id)
    assert {:ok, _} = EmailDelivery.publish(scope, plan)
    count = length(Agent.get(TestProvider, & &1.writes))
    assert count == 4
    assert {:error, _} = EmailDelivery.publish(scope, plan)
    {:ok, fresh} = EmailDelivery.preview(scope, setting.domain_id)
    assert {:ok, _} = EmailDelivery.publish(scope, fresh)
    assert length(Agent.get(TestProvider, & &1.writes)) == count
  end

  test "publication reports partial failure and does not falsely verify", %{
    scope: scope,
    setting: setting
  } do
    configure(scope, setting)
    Agent.update(TestProvider, &%{&1 | fail_after: 1})
    {:ok, plan} = EmailDelivery.preview(scope, setting.domain_id)
    assert {:error, message} = EmailDelivery.publish(scope, plan)
    assert message =~ "1 changes succeeded"
    assert Enum.all?(EmailDelivery.verify(scope, plan), &(&1.result != :ok))
  end

  test "route changes invalidate a preview and DNS errors stop manual planning", %{
    scope: scope,
    setting: setting
  } do
    configure(scope, setting)
    {:ok, plan} = EmailDelivery.preview(scope, setting.domain_id)

    Hostctl.Hosting.save_domain_smarthost_setting(setting.domain, %{
      enabled: true,
      host: "smtp.provider.example",
      port: 587,
      auth_required: false
    })

    assert {:error, _} = EmailDelivery.publish(scope, plan)
    assert Agent.get(TestProvider, & &1.writes) == []
    Repo.delete_all(Hostctl.Settings.DnsProviderSetting)

    Agent.update(
      TestProvider,
      &%{&1 | lookups: %{{"example.com", "CNAME"} => {:error, "timeout"}}}
    )

    assert {:error, "timeout"} = EmailDelivery.preview(scope, setting.domain_id)
  end

  test "admin scope required and DNS must be visible before signing", %{
    scope: scope,
    domain: domain
  } do
    assert {:error, _} = EmailDelivery.enable_signing(scope, domain.id)

    assert_raise FunctionClauseError, fn ->
      EmailDelivery.list_domains(Scope.for_user(user_fixture()))
    end
  end

  defp rr(type, name, value),
    do: %{id: name <> value, type: type, name: name, value: value, proxied: false}

  defp configure(_scope, setting) do
    Repo.insert!(setting)

    Repo.insert!(%Hostctl.Settings.DnsProviderSetting{
      provider: "cloudflare",
      cloudflare_api_token: "test-token"
    })
  end
end
