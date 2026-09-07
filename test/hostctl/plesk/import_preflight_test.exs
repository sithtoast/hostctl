defmodule Hostctl.Plesk.ImportPreflightTest do
  use ExUnit.Case, async: true
  alias Hostctl.Plesk.ImportPreflight

  test "selects only components needed by selected categories and S3 mounts" do
    inventory = %{"databases" => [%{db_type: "mysql"}, %{db_type: "postgresql"}]}
    targets = %{"static" => %{ftp_mount_enabled: true}}
    assert ImportPreflight.required_features(["dns"], inventory, targets) == []
    assert ImportPreflight.required_features(["ftp_accounts"], %{}, nil) == ["ftp"]
    assert ImportPreflight.required_features(["web_files"], %{}, targets) == ["ftp", "rclone"]

    assert ImportPreflight.required_features(["databases", "mail_content"], inventory, nil) == [
             "email",
             "mysql",
             "postgresql"
           ]
  end

  test "waits for setup and stops at the first failed prerequisite" do
    parent = self()

    installer = fn key ->
      send(parent, {:install, key})
      {:error, :package_install_failed}
    end

    assert {:error, message} =
             ImportPreflight.run(
               ["ftp_accounts", "mail_accounts"],
               %{},
               nil,
               fn key -> send(parent, {:progress, key}) end,
               installer
             )

    assert message =~ "ftp prerequisite failed"
    assert_received {:progress, "ftp"}
    assert_received {:install, "ftp"}
    refute_received {:install, "email"}
  end
end
