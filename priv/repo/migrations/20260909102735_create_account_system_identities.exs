defmodule Hostctl.Repo.Migrations.CreateAccountSystemIdentities do
  use Ecto.Migration

  def change do
    create table(:account_system_identities) do
      # Retain reservations when deleting a login: retained files may still
      # belong to this identity. The original owner ID is never reassigned.
      add :user_id, references(:users, on_delete: :nilify_all)
      add :original_user_id, :bigint, null: false
      add :username, :string, null: false
      add :uid, :bigint
      add :gid, :bigint
      add :state, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:account_system_identities, [:user_id])
    create unique_index(:account_system_identities, [:original_user_id])
    create unique_index(:account_system_identities, [:username])
    create unique_index(:account_system_identities, [:uid])
    create unique_index(:account_system_identities, [:gid])

    create constraint(:account_system_identities, :identity_owner,
             check:
               "original_user_id > 0 AND (user_id IS NULL OR user_id = original_user_id) " <>
                 "AND username = 'hc_' || original_user_id::text"
           )

    create constraint(:account_system_identities, :identity_numeric_ids,
             check:
               "(uid IS NULL AND gid IS NULL) OR " <>
                 "(uid IS NOT NULL AND gid IS NOT NULL AND " <>
                 "uid BETWEEN 1 AND 4294967294 AND gid BETWEEN 1 AND 4294967294)"
           )

    create constraint(:account_system_identities, :identity_state,
             check:
               "state IN ('pending', 'provisioning', 'provisioned', 'migrating', 'ready', 'failed', 'retired') " <>
                 "AND (state NOT IN ('provisioned', 'migrating', 'ready') OR " <>
                 "(uid IS NOT NULL AND gid IS NOT NULL))"
           )
  end
end
