defmodule Hostctl.Repo.Migrations.AddIncludeMailAndBackupMail do
  use Ecto.Migration

  def change do
    alter table(:domain_backup_settings) do
      add :include_mail, :boolean, default: true, null: false
    end

    alter table(:backup_settings) do
      add :backup_mail, :boolean, default: false, null: false
    end
  end
end
