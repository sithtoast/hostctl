defmodule Hostctl.Repo.Migrations.CreateDomainBackupSettings do
  use Ecto.Migration

  def change do
    create table(:domain_backup_settings) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :include_files, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:domain_backup_settings, [:domain_id])
  end
end
