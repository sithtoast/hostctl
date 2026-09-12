defmodule HostctlWeb.PanelLive.PleskImportTest do
  use HostctlWeb.ConnCase
  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures

  setup %{conn: conn} do
    admin = admin_user_fixture()
    scope = Hostctl.Accounts.Scope.for_user(admin)

    {:ok, migration} =
      Hostctl.Plesk.create_migration(scope, %{
        name: "Import test",
        source: "ssh",
        subscriptions: [
          %{
            domain: "import.test",
            owner_login: "admin",
            owner_type: "admin",
            owner_name: nil,
            owner_email: nil,
            system_user: "example",
            subdomains: []
          }
        ],
        domain_configs: %{
          "import.test" => %{
            "categories" => ["web_files"],
            "account_email" => admin.email,
            "inventory_counts" => %{},
            "s3_targets" => %{"" => %{"s3_import" => true}}
          }
        }
      })

    {:ok, conn: log_in_user(conn, admin), scope: scope, migration: migration}
  end

  test "progress renders category result maps and continues receiving updates", %{
    conn: conn,
    migration: migration
  } do
    {:ok, view, _} = live(conn, ~p"/panel/plesk-import")
    view |> element("#toggle-saved-btn") |> render_click()

    view
    |> element("button[phx-click=load_migration][phx-value-id='#{migration.id}']")
    |> render_click()

    render_click(view, "import_step", %{"step" => "progress"})

    send(
      view.pid,
      {:restore_progress, "import.test", "cron_jobs", 1, 4,
       %{created: 0, skipped: 0, failed: 0, errors: [], note: "Cron import unavailable"}}
    )

    assert has_element?(view, "#import-progress-import\\.test", "Cron import unavailable")
    send(view.pid, {:restore_progress, "import.test", "web_files", 2, 4, :in_progress})
    assert has_element?(view, "#import-progress-import\\.test", "Working")

    send(
      view.pid,
      {:restore_progress, "import.test", "web_files", 2, 4,
       %{created: 1, skipped: 0, failed: 0, errors: []}}
    )

    assert has_element?(view, "#import-progress-import\\.test", "1 created")
  end

  test "save and reuse a connection without losing destination choices", %{
    conn: conn,
    scope: scope,
    migration: migration
  } do
    {:ok, view, _} = live(conn, ~p"/panel/plesk-import")
    view |> element("#toggle-saved-btn") |> render_click()

    view
    |> element("button[phx-click=load_migration][phx-value-id='#{migration.id}']")
    |> render_click()

    assert has_element?(view, "#s3-config-form-import\\.test-")

    form = %{
      "destination" => %{
        "endpoint" => "s3.wasabisys.com",
        "bucket" => "existing-bucket",
        "region" => "us-east-1",
        "access_key" => "key",
        "secret_key" => "secret",
        "connection_name" => "My Wasabi",
        "prefix" => "archive",
        "ftp_enabled" => "true",
        "directory_listing" => "true"
      }
    }

    view |> form("#s3-config-form-import\\.test-", form) |> render_submit()
    assert [connection] = Hostctl.S3Connections.list(scope)
    assert has_element?(view, "#s3-import\\.test--saved option[value='#{connection.id}']")

    view
    |> form("#s3-import\\.test--connection", %{
      "connection" => %{"id" => to_string(connection.id)}
    })
    |> render_change()

    assert has_element?(view, "#s3-import\\.test--endpoint[value='https://s3.wasabisys.com']")
    assert has_element?(view, "#s3-import\\.test--bucket[value='existing-bucket']")
    assert has_element?(view, "#s3-import\\.test--ftp[checked]")
    assert has_element?(view, "#s3-import\\.test--listing[checked]")
  end

  test "regular users cannot access the importer", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    assert {:error, {:redirect, _}} = live(conn, ~p"/panel/plesk-import")
  end
end
