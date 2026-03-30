defmodule Hostctl.Repo.Migrations.CreateDomainBandwidthSnapshots do
  use Ecto.Migration

  def change do
    create table(:domain_bandwidth_snapshots) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :year, :integer, null: false
      add :month, :integer, null: false
      add :mb_used, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:domain_bandwidth_snapshots, [:domain_id, :year, :month])
    create index(:domain_bandwidth_snapshots, [:domain_id])
  end
end
