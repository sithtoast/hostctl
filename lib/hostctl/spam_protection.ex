defmodule Hostctl.SpamProtection do
  @moduledoc "Admin-managed spam policy. Saving stages changes; applying changes the mail server."
  import Ecto.Query
  alias Hostctl.Repo
  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting.EmailAccount
  alias Hostctl.SpamProtection.{Setting, MailboxPolicy, Config}

  def get_setting(%Scope{user: %{role: "admin"}}), do: Repo.get(Setting, 1) || %Setting{id: 1}

  def save_setting(%Scope{user: %{role: "admin"}} = scope, attrs) do
    locked(fn -> get_setting(scope) |> Setting.changeset(attrs) |> Repo.insert_or_update() end)
  end

  def list_mailboxes(%Scope{user: %{role: "admin"}}) do
    Repo.all(
      from a in EmailAccount,
        join: d in assoc(a, :domain),
        order_by: [d.name, a.username],
        preload: [domain: d]
    )
  end

  def get_policy(%Scope{user: %{role: "admin"}}, account_id) do
    account = Repo.get!(EmailAccount, account_id) |> Repo.preload(:domain)

    policy =
      Repo.get_by(MailboxPolicy, email_account_id: account.id) ||
        %MailboxPolicy{email_account_id: account.id}

    %{policy | email_account: account}
  end

  def save_policy(%Scope{user: %{role: "admin"}} = scope, account_id, attrs) do
    locked(fn ->
      get_policy(scope, account_id) |> MailboxPolicy.changeset(attrs) |> Repo.insert_or_update()
    end)
  end

  def bundle(%Scope{user: %{role: "admin"}} = scope) do
    policies =
      Repo.all(
        from p in MailboxPolicy,
          order_by: p.email_account_id,
          preload: [email_account: :domain]
      )

    Config.bundle(get_setting(scope), policies, Hostctl.EmailDelivery.signing_domains(scope))
  end

  def apply(%Scope{user: %{role: "admin"}} = scope) do
    locked(fn -> adapter().apply(bundle(scope)) end)
  end

  def status(%Scope{user: %{role: "admin"}} = scope) do
    desired = bundle(scope)
    actual = adapter().status()
    Map.put(actual, :pending?, actual.digest != desired.digest)
  end

  defp adapter,
    do: Application.get_env(:hostctl, :spam_protection_adapter, Hostctl.SpamProtection.System)

  defp locked(fun), do: :global.trans({{__MODULE__, :configuration}, self()}, fun)
end
