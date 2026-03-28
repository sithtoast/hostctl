defmodule HostctlWeb.UserLive.RegistrationTest do
  use HostctlWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Hostctl.AccountsFixtures

  describe "Panel Users page" do
    test "redirects unauthenticated users to login", %{conn: conn} do
      {:error, redirect} = live(conn, ~p"/panel/users")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end

    test "redirects non-admin users to home", %{conn: conn} do
      user = user_fixture()

      result =
        conn
        |> log_in_user(user)
        |> live(~p"/panel/users")

      assert {:error, {:redirect, %{to: "/"}}} = result
    end

    test "renders panel users page for admins", %{conn: conn} do
      admin = admin_user_fixture()
      {:ok, _lv, html} = conn |> log_in_user(admin) |> live(~p"/panel/users")

      assert html =~ "Panel Users"
      assert html =~ "Invite User"
    end
  end

  describe "create panel user" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      {:ok, conn: log_in_user(conn, admin)}
    end

    test "invites a new user and sends login email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/panel/users")

      lv |> element("#open-new-user-btn") |> render_click()

      email = unique_user_email()

      html =
        lv
        |> form("#new-user-form", user: %{name: "Test User", email: email})
        |> render_submit()

      assert html =~ "Invite sent to #{email}"
    end

    test "renders errors for duplicate email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/panel/users")

      existing = user_fixture()

      lv |> element("#open-new-user-btn") |> render_click()

      result =
        lv
        |> form("#new-user-form", user: %{name: "Dup User", email: existing.email})
        |> render_submit()

      assert result =~ "has already been taken"
    end

    test "renders errors for missing name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/panel/users")

      lv |> element("#open-new-user-btn") |> render_click()

      result =
        lv
        |> form("#new-user-form", user: %{name: "", email: unique_user_email()})
        |> render_submit()

      assert result =~ "can&#39;t be blank"
    end
  end
end
