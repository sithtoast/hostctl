defmodule Hostctl.Repo.Migrations.AddDomainCloudflareToken do
  use Ecto.Migration

  def change do
    alter table(:dns_zones) do
      add :cloudflare_api_token, :text
    end
  end
end
