defmodule Hostctl.Repo.Migrations.AddBandwidthToDomains do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add :bandwidth_used_mb, :integer, default: 0, null: false
    end
  end
end
