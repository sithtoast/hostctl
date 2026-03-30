defmodule Hostctl.Repo.Migrations.AddBackupMysqlToBackupSettings do
  use Ecto.Migration

  def change do
    alter table(:backup_settings) do
      add :backup_mysql, :boolean, default: false, null: false
    end
  end
end
