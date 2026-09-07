defmodule HostctlWeb.PanelLive.EmailDeliveryLiveTest do
  use HostctlWeb.ConnCase
  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures
  alias Hostctl.EmailDelivery.TestProvider

  setup %{conn: conn} do
    start_supervised!(%{
      id: TestProvider,
      start:
        {Agent, :start_link,
         [
           fn -> %{records: [], lookups: %{}, writes: [], fail_after: nil} end,
           [name: TestProvider]
         ]}
    })

    previous = Application.get_env(:hostctl, :email_delivery_dns)
    Application.put_env(:hostctl, :email_delivery_dns, TestProvider)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :email_delivery_dns, previous),
        else: Application.delete_env(:hostctl, :email_delivery_dns)
    end)

    admin = admin_user_fixture()
    domain = Hostctl.Repo.insert!(%Hostctl.Hosting.Domain{name: "example.com", user_id: admin.id})
    %{conn: log_in_user(conn, admin), domain: domain}
  end

  test "admin can preview and verify without claiming manual DNS was published", %{
    conn: conn,
    domain: domain
  } do
    {:ok, view, _} = live(conn, ~p"/panel/email-delivery")
    view |> element("#domains-#{domain.id}") |> render_click()
    assert has_element?(view, "#delivery-form")
    view |> form("#delivery-form", setting: %{ipv4: "203.0.113.10"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#delivery-records article", "SPF")
    refute has_element?(view, "#publish-delivery")
    view |> element("#verify-delivery") |> render_click()
    render_async(view)
    assert has_element?(view, "#delivery-checks", "Not yet matching public DNS")
  end

  test "invalid IP input does not start a DNS change", %{conn: conn, domain: domain} do
    {:ok, view, _} = live(conn, ~p"/panel/email-delivery")
    view |> element("#domains-#{domain.id}") |> render_click()
    view |> form("#delivery-form", setting: %{ipv4: "not-an-ip"}) |> render_submit()
    assert has_element?(view, "#delivery-form p", "enter a valid IP address")
    refute has_element?(view, "#delivery-busy")
  end

  test "client, reseller and signed-out users cannot access delivery setup", %{conn: conn} do
    for role <- ["client", "reseller"] do
      user = user_fixture() |> Ecto.Changeset.change(role: role) |> Hostctl.Repo.update!()
      assert {:error, {:redirect, _}} = live(log_in_user(conn, user), ~p"/panel/email-delivery")
    end

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/panel/email-delivery")
  end
end
