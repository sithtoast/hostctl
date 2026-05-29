defmodule Hostctl.Repo.Migrations.AddCoversWildcardSubdomainsToSslCertificates do
  use Ecto.Migration

  def change do
    alter table(:ssl_certificates) do
      add :covers_wildcard_subdomains, :boolean, null: false, default: false
    end
  end
end
