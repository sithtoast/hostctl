defmodule Hostctl.Repo.Migrations.CreateDnsTemplates do
  use Ecto.Migration

  def change do
    create table(:dns_template_records) do
      add :type, :string, null: false
      add :name, :string, null: false
      add :value, :string, null: false
      add :ttl, :integer, null: false, default: 3600
      add :priority, :integer
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    alter table(:domains) do
      add :apply_dns_template, :boolean, null: false, default: true
    end
  end
end
