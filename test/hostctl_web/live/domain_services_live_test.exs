defmodule HostctlWeb.DomainServicesLiveTest do
  use HostctlWeb.ConnCase
  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures
  alias Hostctl.{Hosting, Settings}

  setup %{conn: conn} do
    user = user_fixture()
    Settings.load_default_dns_template_records()
    %{conn: log_in_user(conn, user), scope: user_scope_fixture(user)}
  end

  test "new domain service checkboxes persist mail opt-out and hide mailbox controls", ctx do
    {:ok, view, _} = live(ctx.conn, "/domains/new")
    assert has_element?(view, "#domain_web_enabled[checked]")
    assert has_element?(view, "#domain_mail_enabled[checked]")
    assert has_element?(view, "#domain_apply_dns_template[checked]")

    view
    |> form("#domain-form", domain: %{name: "external-mail.com", mail_enabled: false})
    |> render_submit()

    domain = Hosting.get_domain_by_name(ctx.scope, "external-mail.com")
    refute domain.mail_enabled
    records = Hosting.get_dns_zone_with_records!(domain).dns_records
    refute Enum.any?(records, &(&1.type == "MX"))

    {:ok, show, _} = live(ctx.conn, "/domains/#{domain.id}")
    assert has_element?(show, "#domain-hosting-summary", "Mail hosting: Not hosted here")
    refute has_element?(show, "#domain-email-link")

    {:ok, email, _} = live(ctx.conn, "/email")
    refute has_element?(email, "option[value='#{domain.id}']")
  end

  test "mail-only form disables web fields and omitting templates creates an empty zone", ctx do
    {:ok, view, _} = live(ctx.conn, "/domains/new")
    view |> form("#domain-form", domain: %{web_enabled: false}) |> render_change()
    assert has_element?(view, "#domain_php_version[disabled]")
    assert has_element?(view, "#domain_document_root[disabled]")

    view
    |> form("#domain-form",
      domain: %{name: "mail-only.com", web_enabled: false, apply_dns_template: false}
    )
    |> render_submit()

    domain = Hosting.get_domain_by_name(ctx.scope, "mail-only.com")
    refute domain.web_enabled
    assert domain.mail_enabled
    assert Hosting.get_dns_zone_with_records!(domain).dns_records == []
    {:ok, show, _} = live(ctx.conn, "/domains/#{domain.id}")
    refute has_element?(show, "#domain-tab-ssl")
    refute has_element?(show, "#domain-statistics-link")
  end
end
