defmodule Hostctl.Repo.Migrations.AddDigitaloceanDnsProvider do
  use Ecto.Migration

  def change do
    alter table(:dns_provider_settings) do
      add :digitalocean_api_token, :text
    end

    alter table(:dns_zones) do
      add :provider, :string, null: false, default: "inherit"
      add :digitalocean_api_token, :text
      add :digitalocean_zone_name, :string
    end

    alter table(:dns_records) do
      add :digitalocean_record_id, :string
    end

    create index(:dns_records, [:dns_zone_id, :digitalocean_record_id])

    create constraint(:dns_zones, :dns_zones_provider_check,
             check: "provider IN ('inherit', 'local', 'cloudflare', 'digitalocean')"
           )
  end
end
