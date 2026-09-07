defmodule Hostctl.SpamProtectionTest do
  use Hostctl.DataCase
  import Hostctl.AccountsFixtures
  alias Hostctl.{Repo, SpamProtection}
  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting.{Domain, EmailAccount}
  alias Hostctl.SpamProtection.{MailboxPolicy, Setting, TestAdapter}

  setup do
    prior = Application.get_env(:hostctl, :spam_protection_adapter)
    Application.put_env(:hostctl, :spam_protection_adapter, TestAdapter)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:hostctl, :spam_protection_adapter, prior),
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
    domain = Repo.insert!(%Domain{name: "spam.test", user_id: admin.id})

    account =
      Repo.insert!(%EmailAccount{
        username: "inbox",
        hashed_password: "unused-in-policy-tests",
        domain_id: domain.id
      })

    %{scope: Scope.for_user(admin), account: account}
  end

  test "starts disabled and tracks saved versus applied policy", %{scope: scope} do
    assert %Setting{enabled: false, junk_score: 6, learning: true} =
             SpamProtection.get_setting(scope)

    assert {:ok, _} = SpamProtection.save_setting(scope, %{enabled: true})
    assert SpamProtection.status(scope).pending?
    refute SpamProtection.status(scope).enabled
    assert :ok = SpamProtection.apply(scope)
    assert %{enabled: true, healthy?: true, pending?: false} = SpamProtection.status(scope)
    assert {:ok, _} = SpamProtection.save_setting(scope, %{junk_score: 8})
    assert SpamProtection.status(scope).pending?
  end

  test "failed apply does not claim saved settings are active", %{scope: scope} do
    assert {:ok, _} = SpamProtection.save_setting(scope, %{enabled: true})
    Agent.update(TestAdapter, &%{&1 | result: {:error, "validation failed"}})
    assert {:error, "validation failed"} = SpamProtection.apply(scope)
    assert %{enabled: false, pending?: true} = SpamProtection.status(scope)
  end

  test "mailbox rules normalize addresses, reject overlap and allow restoring defaults", %{
    scope: scope,
    account: account
  } do
    assert {:ok, policy} =
             SpamProtection.save_policy(scope, account.id, %{
               "junk_score" => "4",
               "allow_senders" => "Good@Example.com, good@example.com"
             })

    assert policy.allow_senders == "good@example.com"
    assert policy.junk_score == 4

    assert {:error, invalid} =
             SpamProtection.save_policy(scope, account.id, %{
               "block_senders" => "good@example.com"
             })

    assert errors_on(invalid).block_senders == ["cannot also appear in allowed senders"]

    assert {:ok, policy} =
             SpamProtection.save_policy(scope, account.id, %{
               "junk_score" => "",
               "allow_senders" => ""
             })

    assert policy.junk_score == nil
    assert policy.allow_senders == ""
  end

  test "thresholds cannot disable sorting with an invalid score", %{
    scope: scope,
    account: account
  } do
    for score <- [0, 21, "6.5", "garbage", nil] do
      assert {:error, _} = SpamProtection.save_setting(scope, %{junk_score: score})
    end

    for score <- [0, 21, "6.5"] do
      assert {:error, _} = SpamProtection.save_policy(scope, account.id, %{junk_score: score})
    end
  end

  test "sender rules reject script injection and wildcards", %{scope: scope, account: account} do
    for sender <- ["*@example.com", "a@example.com\"; discard;", "\"\nstop;", "not-an-email"] do
      assert {:error, _} = SpamProtection.save_policy(scope, account.id, %{allow_senders: sender})
    end
  end

  test "mailbox deletion removes its policy", %{scope: scope, account: account} do
    assert {:ok, _} = SpamProtection.save_policy(scope, account.id, %{junk_score: 3})
    Repo.delete!(account)
    assert Repo.all(MailboxPolicy) == []
  end

  test "only an administrator can read, save or apply server policy", %{account: account} do
    client = user_scope_fixture()
    assert_raise FunctionClauseError, fn -> SpamProtection.get_setting(client) end

    assert_raise FunctionClauseError, fn ->
      SpamProtection.save_setting(client, %{enabled: true})
    end

    assert_raise FunctionClauseError, fn -> SpamProtection.list_mailboxes(client) end
    assert_raise FunctionClauseError, fn -> SpamProtection.get_policy(client, account.id) end

    assert_raise FunctionClauseError, fn ->
      SpamProtection.save_policy(client, account.id, %{})
    end

    assert_raise FunctionClauseError, fn -> SpamProtection.apply(client) end
    assert_raise FunctionClauseError, fn -> SpamProtection.status(client) end
  end
end
