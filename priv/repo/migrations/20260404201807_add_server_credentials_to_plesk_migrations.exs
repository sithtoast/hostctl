defmodule Hostctl.Repo.Migrations.AddServerCredentialsToPleskMigrations do
  use Ecto.Migration

  def change do
    alter table(:plesk_migrations) do
      add :server_credentials, :map, default: %{}
    end
  end
end
