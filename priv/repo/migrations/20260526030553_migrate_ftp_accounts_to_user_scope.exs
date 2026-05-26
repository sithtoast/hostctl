defmodule Hostctl.Repo.Migrations.MigrateFtpAccountsToUserScope do
  use Ecto.Migration

  def change do
    # Add reseller→client scoping: each user can optionally belong to a reseller
    alter table(:users) do
      add :managed_by_id, references(:users, on_delete: :nilify_all), null: true
    end

    # Migrate ftp_accounts from domain-scoped to user-scoped
    alter table(:ftp_accounts) do
      add :user_id, references(:users, on_delete: :delete_all), null: true
    end

    # Backfill user_id from the owning domain's user_id
    execute(
      "UPDATE ftp_accounts f SET user_id = d.user_id FROM domains d WHERE f.domain_id = d.id",
      "UPDATE ftp_accounts f SET user_id = NULL"
    )

    # Enforce NOT NULL after backfill
    execute(
      "ALTER TABLE ftp_accounts ALTER COLUMN user_id SET NOT NULL",
      "ALTER TABLE ftp_accounts ALTER COLUMN user_id DROP NOT NULL"
    )

    # Drop the now-redundant domain association
    alter table(:ftp_accounts) do
      remove :domain_id
    end
  end
end
