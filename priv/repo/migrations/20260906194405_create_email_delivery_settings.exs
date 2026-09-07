defmodule Hostctl.Repo.Migrations.CreateEmailDeliverySettings do
  use Ecto.Migration

  def change do
    create table(:email_delivery_settings) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :hostname, :string
      add :ipv4, :string
      add :ipv6, :string
      add :spf_include, :string
      add :dkim_records, :text
      add :selector, :string
      add :public_key, :text
      add :signing_enabled, :boolean, default: false, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:email_delivery_settings, [:domain_id])
  end
end
