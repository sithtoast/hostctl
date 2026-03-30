defmodule Hostctl.Repo.Migrations.AddExcludedDirsToDomainAndSubdomainBackupSettings do
  use Ecto.Migration

  def change do
    alter table(:domain_backup_settings) do
      add :excluded_dirs, {:array, :string}, default: [], null: false
    end

    alter table(:subdomain_backup_settings) do
      add :excluded_dirs, {:array, :string}, default: [], null: false
    end
  end
end
