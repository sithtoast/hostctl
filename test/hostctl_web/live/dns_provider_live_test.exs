defmodule HostctlWeb.DnsProviderLiveTest do
  use HostctlWeb.ConnCase
  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures
  alias Hostctl.{Repo, Settings}
  alias Hostctl.Hosting.{Domain, DnsZone}

  setup do
    previous = Application.get_env(:hostctl, :digitalocean_request_options)
    Application.put_env(:hostctl, :digitalocean_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :digitalocean_request_options, previous),
        else: Application.delete_env(:hostctl, :digitalocean_request_options)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/domains"} ->
          Req.Test.json(conn, %{"domains" => []})

        {"GET", "/v2/domains/example.com"} ->
          Req.Test.json(conn, %{"domain" => %{"name" => "example.com"}})

        {"GET", "/v2/domains/example.com/records"} ->
          Req.Test.json(conn, %{
            "domain_records" => [
              %{
                "id" => 1,
                "type" => "TXT",
                "name" => "@",
                "data" => "verification=test",
                "ttl" => 600
              }
            ]
          })

        _ ->
          flunk("Unexpected remote write")
      end
    end)

    user = user_fixture()
    domain = Repo.insert!(%Domain{user_id: user.id, name: "example.com"})
    zone = Repo.insert!(%DnsZone{domain_id: domain.id})
    %{user: user, domain: domain, zone: zone}
  end

  test "admin saves panel provider, tests saved token, and does not render credentials", ctx do
    admin = user_fixture() |> Ecto.Changeset.change(role: "admin") |> Repo.update!()
    {:ok, view, _} = live(log_in_user(ctx.conn, admin), "/panel/settings")

    view
    |> form("#dns-provider-form", dns_provider: %{provider: "digitalocean"})
    |> render_change()

    assert has_element?(view, "#digitalocean-panel-settings")

    view
    |> form("#dns-provider-form",
      dns_provider: %{provider: "digitalocean", digitalocean_api_token: "panel-secret"}
    )
    |> render_submit()

    assert Settings.get_dns_provider_setting().digitalocean_api_token == "panel-secret"
    refute has_element?(view, "input[value='panel-secret']")
    assert has_element?(view, "#dns_provider_digitalocean_api_token[value='']")
    view |> element("#test-digitalocean-btn") |> render_click()
    assert has_element?(view, "#digitalocean-token-success")
    view |> form("#dns-provider-form", dns_provider: %{provider: "local"}) |> render_submit()
    assert Settings.get_dns_provider_setting().provider == "local"
  end

  test "owners override, link, review and import only their existing domain", ctx do
    {:ok, _} =
      Settings.save_dns_provider_setting(%{
        provider: "cloudflare",
        cloudflare_api_token: "panel-cf-secret",
        digitalocean_api_token: "panel-do-secret"
      })

    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.user), "/domains/#{ctx.domain.id}/dns")
    assert has_element?(view, "#domain-dns-provider-form")

    view
    |> form("#domain-dns-provider-form",
      zone_provider: %{provider: "digitalocean", digitalocean_api_token: "owner-secret"}
    )
    |> render_submit()

    assert has_element?(view, "#digitalocean-zone-panel")
    refute has_element?(view, "#link-cf-btn")

    for token <- ~w(panel-cf-secret panel-do-secret owner-secret),
        do: refute(has_element?(view, "input[value='#{token}']"))

    refute Repo.get!(DnsZone, ctx.zone.id).digitalocean_zone_name
    view |> element("#link-digitalocean-btn") |> render_click()
    assert has_element?(view, "#sync-digitalocean-btn")
    view |> element("#refresh-digitalocean-btn") |> render_click()
    assert has_element?(view, "#digitalocean-remote-records td", "verification=test")
    view |> element("#import-digitalocean-btn") |> render_click()
    assert has_element?(view, "#dns-records td", "verification=test")
    view |> element("#unlink-digitalocean-btn") |> render_click()
    assert has_element?(view, "#link-digitalocean-btn")
  end

  test "resellers save, retain, test and remove their own Cloudflare token without exposing it",
       ctx do
    previous = Application.get_env(:hostctl, :cloudflare_request_options)
    Application.put_env(:hostctl, :cloudflare_request_options, plug: {Req.Test, :domain_cf_ui})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :cloudflare_request_options, previous),
        else: Application.delete_env(:hostctl, :cloudflare_request_options)
    end)

    Req.Test.stub(:domain_cf_ui, fn conn ->
      assert conn.method == "GET"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer reseller-secret"]
      result = if conn.request_path == "/client/v4/zones", do: [%{"id" => "own-zone"}], else: []
      Req.Test.json(conn, %{"success" => true, "result" => result})
    end)

    reseller = ctx.user |> Ecto.Changeset.change(role: "reseller") |> Repo.update!()
    {:ok, view, _} = live(log_in_user(ctx.conn, reseller), "/domains/#{ctx.domain.id}/dns")

    view
    |> form("#domain-dns-provider-form",
      zone_provider: %{provider: "cloudflare", cloudflare_api_token: "reseller-secret"}
    )
    |> render_submit()

    assert has_element?(view, "#domain-cloudflare-token-status", "Cloudflare domain token saved.")
    assert has_element?(view, "#zone_provider_cloudflare_api_token[value='']")
    refute has_element?(view, "input[value='reseller-secret']")

    view
    |> form("#domain-dns-provider-form",
      zone_provider: %{provider: "cloudflare", cloudflare_api_token: ""}
    )
    |> render_submit()

    assert Repo.get!(DnsZone, ctx.zone.id).cloudflare_api_token == "reseller-secret"
    view |> element("#test-domain-cloudflare-btn") |> render_click()
    assert has_element?(view, "#flash-info", "Cloudflare zone read access verified")
    view |> element("#link-cf-btn") |> render_click()
    assert has_element?(view, "#sync-cf-btn")

    view
    |> form("#domain-dns-provider-form", zone_provider: %{clear_cloudflare_token: true})
    |> render_submit()

    refute Repo.get!(DnsZone, ctx.zone.id).cloudflare_api_token
    refute Repo.get!(DnsZone, ctx.zone.id).cloudflare_zone_id
    refute has_element?(view, "#sync-cf-btn")
  end

  test "non-admins cannot open panel credentials and foreign domain access fails", ctx do
    conn = log_in_user(ctx.conn, ctx.user)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/panel/settings")
    foreign = user_fixture()

    assert_raise Ecto.NoResultsError, fn ->
      live(log_in_user(ctx.conn, foreign), "/domains/#{ctx.domain.id}/dns")
    end
  end

  test "manual domain override is preserved when panel default changes", ctx do
    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.user), "/domains/#{ctx.domain.id}/dns")

    view
    |> form("#domain-dns-provider-form", zone_provider: %{provider: "local"})
    |> render_submit()

    {:ok, _} =
      Settings.save_dns_provider_setting(%{
        provider: "digitalocean",
        digitalocean_api_token: "panel"
      })

    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.user), "/domains/#{ctx.domain.id}/dns")
    refute has_element?(view, "#digitalocean-zone-panel")
    assert has_element?(view, "#zone_provider_provider option[value='local'][selected]")
  end
end
