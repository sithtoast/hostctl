defmodule Hostctl.Repo.Migrations.AddEmailToSslCertificates do
  use Ecto.Migration

  def change do
    alter table(:ssl_certificates) do
      add :email, :string
    end
  end
end
