defmodule Hostctl.Repo.Migrations.AddSubdomainToDomainProxies do
  use Ecto.Migration

  def change do
    alter table(:domain_proxies) do
      add :websocket_enabled, :boolean, null: false, default: true
      add :subdomain, :string, null: false, default: ""
      add :upstream_scheme, :string, null: false, default: "http"
    end

    drop unique_index(:domain_proxies, [:domain_id, :path])
    create unique_index(:domain_proxies, [:domain_id, :subdomain, :path])

    create constraint(:domain_proxies, :domain_proxies_upstream_scheme,
             check: "upstream_scheme IN ('http', 'https')"
           )
  end
end
