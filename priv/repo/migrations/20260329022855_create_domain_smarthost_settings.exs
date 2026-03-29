defmodule Hostctl.Repo.Migrations.CreateDomainSmarthostSettings do
  use Ecto.Migration

  def change do
    create table(:domain_smarthost_settings) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :enabled, :boolean, default: false, null: false
      add :host, :string
      add :port, :integer, default: 587
      add :auth_required, :boolean, default: true, null: false
      add :username, :string
      add :password, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:domain_smarthost_settings, [:domain_id])
  end
end
