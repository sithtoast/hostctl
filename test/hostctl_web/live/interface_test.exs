defmodule HostctlWeb.InterfaceTest do
  use HostctlWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures
  alias Hostctl.{Hosting, Repo}

  defp domain(user, name) do
    {:ok, domain} =
      Hosting.create_domain(user_scope_fixture(user), %{name: name, apply_dns_template: false})

    domain
  end

  test "administration routes are protected and navigation is role-aware", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, view, _} = live(conn, "/")
    refute has_element?(view, "#nav-admin")
    refute has_element?(view, "#nav-panel_docker")
    assert {:error, {:redirect, _}} = live(conn, "/panel")
    admin = user |> Ecto.Changeset.change(role: "admin") |> Repo.update!()
    {:ok, view, _} = live(log_in_user(conn, admin), "/panel")
    assert has_element?(view, "#admin-link-panel_docker[href='/panel/docker']")
    assert has_element?(view, "#navigation-toggle[aria-controls='app-sidebar']")

    send(
      view.pid,
      {:update_status, %{status: :ok, available?: true, checked_at: nil, last_success_at: nil}}
    )

    assert has_element?(view, "#nav-updates-badge", "1")
    assert has_element?(view, "#system-update-badge", "1")
  end

  test "database URL scope isolates domains and supports all domains", %{conn: conn} do
    user = user_fixture()
    a = domain(user, "scope-a.example")
    b = domain(user, "scope-b.example")
    {:ok, db_a} = Hosting.create_database(a, %{name: "scope_a_db", db_type: "mysql"})
    {:ok, db_b} = Hosting.create_database(b, %{name: "scope_b_db", db_type: "mysql"})
    {:ok, view, _} = live(log_in_user(conn, user), "/databases?domain_id=#{a.id}")
    assert has_element?(view, "[phx-value-id='#{db_a.id}'][phx-click=toggle_db_users]")
    refute has_element?(view, "[phx-value-id='#{db_b.id}'][phx-click=toggle_db_users]")
    render_patch(view, "/databases?domain_id=all")
    assert has_element?(view, "[phx-value-id='#{db_b.id}'][phx-click=toggle_db_users]")
  end

  test "shared FTP accounts appear in both domains", %{conn: conn} do
    user = user_fixture()
    a = domain(user, "ftp-a.example")
    b = domain(user, "ftp-b.example")

    {:ok, shared} =
      Hosting.create_ftp_account(user, %{
        username: "shared_test",
        password: "valid-password",
        mounts: [
          %{"name" => "a", "path" => a.document_root},
          %{"name" => "b", "path" => b.document_root}
        ]
      })

    {:ok, single} =
      Hosting.create_ftp_account(user, %{
        username: "single_test",
        password: "valid-password",
        home_dir: a.document_root
      })

    {:ok, view, _} = live(log_in_user(conn, user), "/ftp?domain_id=#{b.id}")
    assert has_element?(view, "#ftp-shared-#{shared.id}", "Shared · 2 domains")
    refute has_element?(view, "[phx-click=edit_ftp][phx-value-id='#{single.id}']")
    render_patch(view, "/ftp?domain_id=#{a.id}")
    assert has_element?(view, "#ftp-shared-#{shared.id}")
    assert has_element?(view, "[phx-click=edit_ftp][phx-value-id='#{single.id}']")
  end

  test "cron page edits the selected domain job", %{conn: conn} do
    user = user_fixture()
    d = domain(user, "cron.example")
    {:ok, job} = Hosting.create_cron_job(d, %{command: "echo original", schedule: "0 3 * * *"})
    {:ok, view, _} = live(log_in_user(conn, user), "/cron?domain_id=#{d.id}")
    view |> element("#edit-cron-#{job.id}") |> render_click()

    view
    |> form("#cron-form", cron_job: %{command: "echo changed", schedule: "0 * * * *"})
    |> render_submit()

    assert [%{command: "echo changed"}] = Hosting.list_cron_jobs(d)
    assert has_element?(view, "#cron-jobs", "Every hour")
  end

  test "email scope includes webmail beside each mailbox", %{conn: conn} do
    user = user_fixture()
    a = domain(user, "mail-a.example")
    b = domain(user, "mail-b.example")

    {:ok, _} =
      Hostctl.Settings.save_feature_setting("roundcube", %{enabled: true, status: "installed"})

    {:ok, mail_a} =
      Hosting.create_email_account(a, %{username: "hello", password: "valid-password"})

    {:ok, mail_b} =
      Hosting.create_email_account(b, %{username: "hello", password: "valid-password"})

    {:ok, view, _} = live(log_in_user(conn, user), "/email?domain_id=#{a.id}")
    assert has_element?(view, "#webmail-#{mail_a.id}-roundcube[href='/roundcube']")
    refute has_element?(view, "#webmail-#{mail_b.id}-roundcube")
    render_patch(view, "/email?domain_id=all")
    assert has_element?(view, "#webmail-#{mail_b.id}-roundcube")
  end

  test "saved Plesk migration can be reviewed without starting a restore", %{conn: conn} do
    admin = admin_user_fixture()
    scope = user_scope_fixture(admin)

    {:ok, migration} =
      Hostctl.Plesk.create_migration(scope, %{
        name: "Review migration",
        source: "backup",
        subscriptions: [
          %{
            "domain" => "import.example",
            "owner_login" => "owner",
            "owner_type" => "client",
            "system_user" => "site",
            "subdomains" => []
          }
        ],
        domain_configs: %{
          "import.example" => %{"account_email" => admin.email, "categories" => ["web_files"]}
        }
      })

    {:ok, view, _} = live(log_in_user(conn, admin), "/panel/plesk-import")
    assert has_element?(view, "#plesk-step-review[disabled]")
    view |> element("[phx-click=toggle_saved_migrations]") |> render_click()

    view
    |> element("[phx-click=load_migration][phx-value-id='#{migration.id}']")
    |> render_click()

    view |> element("#plesk-step-review") |> render_click()
    assert has_element?(view, "#plesk-review")
    assert has_element?(view, "#confirm-plesk-import:not([disabled])")
    assert Hosting.list_domains(scope) == []
    view |> element("#plesk-step-progress") |> render_click()
    assert has_element?(view, "#plesk-progress")
  end

  test "domain filters combine search, status, and HTTPS", %{conn: conn} do
    user = user_fixture()
    a = domain(user, "filter-a.example")
    b = domain(user, "filter-b.example")
    b |> Ecto.Changeset.change(status: "suspended", ssl_enabled: true) |> Repo.update!()
    {:ok, view, _} = live(log_in_user(conn, user), "/domains")

    view
    |> form("#domain-filters", %{query: "filter", status: "suspended", ssl: "enabled"})
    |> render_change()

    assert has_element?(view, "#domains-#{b.id}")
    refute has_element?(view, "#domains-#{a.id}")

    view
    |> form("#domain-filters", %{query: "missing", status: "all", ssl: "all"})
    |> render_change()

    assert has_element?(view, "p", "No matching domains")
    refute has_element?(view, "#domains-#{b.id}")
    view |> form("#domain-filters", %{query: "", status: "all", ssl: "all"}) |> render_change()
    assert has_element?(view, "#domains-#{a.id}")
    assert has_element?(view, "#domains-#{b.id}")
  end

  test "domain overview exposes storage and retains section navigation", %{conn: conn} do
    user = user_fixture()
    d = domain(user, "overview.example")

    {:ok, backend} =
      Hosting.create_s3_backend(d, %{
        endpoint_url: "https://s3.example.com",
        bucket: "site-assets",
        url_path: "/media"
      })

    {:ok, view, _} = live(log_in_user(conn, user), "/domains/#{d.id}")
    assert has_element?(view, "#domain-hosting-configuration")
    assert has_element?(view, "#storage-summary-#{backend.id}", "site-assets")
    view |> element("#domain-https-settings") |> render_click()
    assert has_element?(view, "#domain-tab-ssl[aria-pressed=true]")
    view |> element("#domain-tab-overview") |> render_click()
    assert has_element?(view, "#domain-services")
  end
end
