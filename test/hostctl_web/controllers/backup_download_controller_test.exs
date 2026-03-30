defmodule HostctlWeb.BackupDownloadControllerTest do
  use HostctlWeb.ConnCase, async: true

  import Hostctl.AccountsFixtures

  alias Hostctl.Backup

  describe "GET /panel/backups/:id/download" do
    test "redirects unauthenticated users to login", %{conn: conn} do
      conn = get(conn, ~p"/panel/backups/123/download")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "redirects non-admin users", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/panel/backups/123/download")

      assert redirected_to(conn) == ~p"/"
    end

    test "downloads local backup for admin users", %{conn: conn} do
      admin = admin_user_fixture()

      archive_path =
        Path.join(
          System.tmp_dir!(),
          "hostctl-backup-download-test-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}.tar.gz"
        )

      :ok = File.write(archive_path, "test-backup-bytes")
      on_exit(fn -> File.rm(archive_path) end)

      {:ok, log} =
        Backup.create_log(%{
          status: "success",
          trigger: "manual",
          destination: "local",
          local_path: archive_path,
          file_size_bytes: 17,
          completed_at: DateTime.utc_now()
        })

      conn =
        conn
        |> log_in_user(admin)
        |> get(~p"/panel/backups/#{log.id}/download")

      assert conn.status == 200
      assert conn.resp_body == "test-backup-bytes"

      disposition = get_resp_header(conn, "content-disposition") |> Enum.join(";")
      assert disposition =~ "attachment"
      assert disposition =~ Path.basename(archive_path)
    end
  end
end
