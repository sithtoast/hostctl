defmodule Hostctl.Repo.Migrations.CreateSpamProtection do
  use Ecto.Migration

  def change do
    create table(:spam_settings, primary_key: false) do
      add :id, :integer, primary_key: true
      add :enabled, :boolean, default: false, null: false
      add :learning, :boolean, default: true, null: false
      add :junk_score, :integer, default: 6, null: false
      timestamps(type: :utc_datetime)
    end

    create constraint(:spam_settings, :singleton, check: "id = 1")
    create constraint(:spam_settings, :valid_junk_score, check: "junk_score BETWEEN 1 AND 20")

    create table(:spam_mailbox_policies) do
      add :email_account_id, references(:email_accounts, on_delete: :delete_all), null: false
      add :junk_score, :integer
      add :allow_senders, :text, default: "", null: false
      add :block_senders, :text, default: "", null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:spam_mailbox_policies, [:email_account_id])

    create constraint(:spam_mailbox_policies, :valid_mailbox_junk_score,
             check: "junk_score IS NULL OR junk_score BETWEEN 1 AND 20"
           )
  end
end
