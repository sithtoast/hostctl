defmodule Hostctl.Repo.Migrations.CreatePleskMigrations do
  use Ecto.Migration

  def change do
    create table(:plesk_migrations) do
      add :name, :string, null: false
      add :source, :string, null: false
      add :status, :string, null: false, default: "discovered"
      add :source_params, :map, default: %{}
      add :subscriptions, {:array, :map}, default: []
      add :inventory, :map, default: %{}
      add :domain_configs, :map, default: %{}
      add :restore_results, :map, default: %{}
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:plesk_migrations, [:user_id])
  end
end
