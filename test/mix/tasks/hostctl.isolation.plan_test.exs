defmodule Mix.Tasks.Hostctl.Isolation.PlanTest do
  use Hostctl.DataCase

  import Hostctl.AccountsFixtures

  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting.Domain
  alias Hostctl.Isolation
  alias Mix.Tasks.Hostctl.Isolation.Plan

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)
    :ok
  end

  test "requires an unambiguous positive owner ID and rejects apply mode" do
    for args <- [
          [],
          ["--user-id", "0"],
          ["--user-id", "-1"],
          ["--user-id", "x"],
          ["--user-id", "1", "--apply"],
          ["--user-id", "1", "extra"],
          ["--user-id", "1", "--user-id", "2"]
        ] do
      assert_raise Mix.Error, ~r/Usage:/, fn -> Plan.run(args) end
    end
  end

  test "prints JSON inventory by default and reserves only when explicitly requested" do
    user = unconfirmed_user_fixture()
    scope = Scope.for_user(user)
    Repo.insert!(%Domain{user_id: user.id, name: "cli.example.com"})

    Plan.run(["--user-id", to_string(user.id)])
    assert_receive {:mix_shell, :info, [json]}

    assert %{"identity" => %{"state" => "unreserved"}, "apply_supported" => false} =
             Jason.decode!(json)

    assert Isolation.get_identity(scope) == nil

    Plan.run(["--user-id", to_string(user.id), "--reserve"])
    assert_receive {:mix_shell, :info, [json]}
    assert %{"identity" => %{"state" => "pending", "uid" => nil}} = Jason.decode!(json)
    assert Isolation.get_identity(scope).state == :pending
  end

  test "unknown owners fail with a concise error" do
    previous_level = Logger.get_process_level(self())

    assert_raise Mix.Error, "Hosting owner not found", fn ->
      Plan.run(["--user-id", "9223372036854775000"])
    end

    assert Logger.get_process_level(self()) == previous_level
  end
end
