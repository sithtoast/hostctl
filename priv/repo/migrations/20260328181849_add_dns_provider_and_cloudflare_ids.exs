defmodule Hostctl.Repo.Migrations.AddDnsProviderAndCloudflareIds do
  use Ecto.Migration

  def change do
    create table(:dns_provider_settings) do
      add :provider, :string, null: false, default: "local"
      add :cloudflare_api_token, :text

      timestamps(type: :utc_datetime)
    end

    alter table(:dns_zones) do
      add :cloudflare_zone_id, :string
    end

    alter table(:dns_records) do
      add :cloudflare_record_id, :string
    end
  end
end
