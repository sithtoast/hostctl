defmodule Hostctl.Repo.Migrations.CreateDomainProxies do
  use Ecto.Migration

  def change do
    create table(:domain_proxies) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :container_name, :string, null: false
      add :upstream_port, :integer, null: false
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:domain_proxies, [:domain_id])
    create unique_index(:domain_proxies, [:domain_id, :path])
  end
end
