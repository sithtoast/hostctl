defmodule HostctlWeb.ResourcesLiveTest do
  use HostctlWeb.ConnCase
  import Phoenix.LiveViewTest
  import Hostctl.ResourceFixtures
  alias Hostctl.AccountsFixtures

  setup do
    resource_fixture()
  end

  test "requires login and administrator role", %{conn: conn, owner: owner} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/panel/resources")

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in_user(owner) |> live(~p"/panel/resources")

    reseller =
      AccountsFixtures.user_fixture()
      |> Ecto.Changeset.change(role: "reseller")
      |> Hostctl.Repo.update!()

    assert {:error, {:redirect, %{to: "/"}}} =
             conn |> log_in_user(reseller) |> live(~p"/panel/resources")
  end

  test "admin can search processes and refresh without exposing stale results", %{
    conn: conn,
    admin: admin,
    processes: processes
  } do
    {:ok, view, _} = conn |> log_in_user(admin) |> live(~p"/panel/resources")
    render_async(view)
    assert has_element?(view, "#resources-total", "3")
    assert has_element?(view, "#processes-410", "Cedar Hosting")
    assert has_element?(view, "#processes-410", "shop.cedar.example")
    assert has_element?(view, "#processes-1", "System / shared service")

    view |> form("#resources-search", search: %{query: "maple"}) |> render_change()
    render_async(view)
    assert has_element?(view, "#processes-420")
    refute has_element?(view, "#processes-410")

    view |> form("#resources-search", search: %{query: ""}) |> render_change()
    render_async(view)
    set_processes({:ok, Enum.reject(processes, &(&1.pid == 410))})
    view |> element("#resources-refresh") |> render_click()
    render_async(view)
    refute has_element?(view, "#processes-410")
    assert has_element?(view, "#resources-total", "2")

    set_processes({:error, :process_access_failed})
    view |> element("#resources-refresh") |> render_click()
    render_async(view)
    assert has_element?(view, "#resources-error")
    refute has_element?(view, "#processes-420")
    assert has_element?(view, "#resources-timestamp", "Not sampled")
  end

  test "administration links to account resources", %{conn: conn, admin: admin} do
    {:ok, view, _} = conn |> log_in_user(admin) |> live(~p"/panel/system")
    assert has_element?(view, "#admin-link-panel_resources[href='/panel/resources']")
  end
end
