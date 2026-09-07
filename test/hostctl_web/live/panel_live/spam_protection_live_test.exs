defmodule HostctlWeb.PanelLive.SpamProtectionLiveTest do
  use HostctlWeb.ConnCase
  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures
  alias Hostctl.SpamProtection.TestAdapter

  setup %{conn: conn} do
    previous = Application.get_env(:hostctl, :spam_protection_adapter)
    Application.put_env(:hostctl, :spam_protection_adapter, TestAdapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :spam_protection_adapter, previous),
        else: Application.delete_env(:hostctl, :spam_protection_adapter)
    end)

    start_supervised!(%{
      id: TestAdapter,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               result: :ok,
               actual: %{enabled: false, healthy?: false, digest: nil, message: "Disabled"}
             }
           end,
           [name: TestAdapter]
         ]}
    })

    admin = admin_user_fixture()
    domain = Hostctl.Repo.insert!(%Hostctl.Hosting.Domain{name: "mail.test", user_id: admin.id})

    account =
      Hostctl.Repo.insert!(%Hostctl.Hosting.EmailAccount{
        username: "hello",
        hashed_password: "unused-in-policy-tests",
        domain_id: domain.id
      })

    %{conn: log_in_user(conn, admin), account: account}
  end

  test "admin can save and apply protection", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/panel/spam-protection")
    render_async(view)
    assert has_element?(view, "#spam-settings-form")

    view
    |> form("#spam-settings-form", setting: %{enabled: true, junk_score: 5})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#spam-pending")
    view |> element("#apply-spam-settings") |> render_click()
    render_async(view)
    # Apply completion schedules an independent status request.
    render_async(view)
    assert has_element?(view, "#spam-apply-result")
    refute has_element?(view, "#spam-pending")
  end

  test "mailbox editor supports defaults and validation", %{conn: conn, account: account} do
    {:ok, view, _} = live(conn, ~p"/panel/spam-protection")
    view |> element("#mailboxes-#{account.id}") |> render_click()
    assert has_element?(view, "#spam-mailbox-form")

    view
    |> form("#spam-mailbox-form",
      mailbox_policy: %{junk_score: "3", allow_senders: "friend@example.com"}
    )
    |> render_submit()

    assert has_element?(view, "#mailbox_policy_junk_score[value='3']")
    view |> form("#spam-mailbox-form", mailbox_policy: %{junk_score: ""}) |> render_submit()
    refute has_element?(view, "#mailbox_policy_junk_score[value='3']")

    view
    |> form("#spam-mailbox-form", mailbox_policy: %{allow_senders: "*@example.com"})
    |> render_submit()

    assert has_element?(view, "#spam-mailbox-form p", "enter full email addresses")
  end

  test "failed apply is visible and remains pending", %{conn: conn} do
    Agent.update(TestAdapter, &%{&1 | result: {:error, "Configuration validation failed"}})
    {:ok, view, _} = live(conn, ~p"/panel/spam-protection")
    view |> element("#apply-spam-settings") |> render_click()
    render_async(view)
    render_async(view)
    assert has_element?(view, "#spam-apply-result", "Configuration validation failed")
    assert has_element?(view, "#spam-pending")
  end

  test "client, reseller and signed-out visitors cannot access the page", %{conn: conn} do
    for role <- ["client", "reseller"] do
      user = user_fixture() |> Ecto.Changeset.change(role: role) |> Hostctl.Repo.update!()
      assert {:error, {:redirect, _}} = live(log_in_user(conn, user), ~p"/panel/spam-protection")
    end

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/panel/spam-protection")
  end
end
