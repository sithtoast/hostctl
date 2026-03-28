defmodule Hostctl.Repo.Migrations.AddLogToSslCertificates do
  use Ecto.Migration

  def change do
    alter table(:ssl_certificates) do
      add :log, :text
    end
  end
end
