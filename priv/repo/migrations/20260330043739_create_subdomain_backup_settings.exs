defmodule Hostctl.Repo.Migrations.CreateSubdomainBackupSettings do
  use Ecto.Migration

  def change do
    create table(:subdomain_backup_settings) do
      add :subdomain_id, references(:subdomains, on_delete: :delete_all), null: false
      add :include_files, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subdomain_backup_settings, [:subdomain_id])
  end
end
