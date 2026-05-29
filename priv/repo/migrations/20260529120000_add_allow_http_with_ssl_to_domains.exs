defmodule Hostctl.Repo.Migrations.AddAllowHttpWithSslToDomains do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add :allow_http_with_ssl, :boolean, null: false, default: false
    end
  end
end
