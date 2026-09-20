defmodule Hostctl.Repo.Migrations.AddDomainHostingServices do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add :web_enabled, :boolean, default: true, null: false
      add :mail_enabled, :boolean, default: true, null: false
    end

    alter table(:dns_template_records) do
      add :service, :string, default: "auto", null: false
    end
  end
end
