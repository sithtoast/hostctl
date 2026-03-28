defmodule Hostctl.Repo.Migrations.CreateHostingTables do
  use Ecto.Migration

  def change do
    create table(:domains) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :document_root, :string
      add :php_version, :string, default: "8.3"
      add :status, :string, null: false, default: "active"
      add :ssl_enabled, :boolean, default: false
      add :disk_usage_mb, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:domains, [:name])
    create index(:domains, [:user_id])

    create table(:subdomains) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :document_root, :string
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subdomains, [:domain_id, :name])
    create index(:subdomains, [:domain_id])

    create table(:dns_zones) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :ttl, :integer, default: 3600
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dns_zones, [:domain_id])

    create table(:dns_records) do
      add :dns_zone_id, references(:dns_zones, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :name, :string, null: false
      add :value, :string, null: false
      add :ttl, :integer, default: 3600
      add :priority, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:dns_records, [:dns_zone_id])

    create table(:email_accounts) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :username, :string, null: false
      add :hashed_password, :string, null: false
      add :quota_mb, :integer, default: 1024
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:email_accounts, [:domain_id, :username])
    create index(:email_accounts, [:domain_id])

    create table(:databases) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :db_type, :string, null: false, default: "postgresql"
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:databases, [:name])
    create index(:databases, [:domain_id])

    create table(:db_users) do
      add :database_id, references(:databases, on_delete: :delete_all), null: false
      add :username, :string, null: false
      add :hashed_password, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:db_users, [:database_id, :username])
    create index(:db_users, [:database_id])

    create table(:ssl_certificates) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :cert_type, :string, null: false, default: "lets_encrypt"
      add :certificate, :text
      add :private_key, :text
      add :expires_at, :utc_datetime
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ssl_certificates, [:domain_id])

    create table(:cron_jobs) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :schedule, :string, null: false
      add :command, :string, null: false
      add :enabled, :boolean, default: true
      add :last_run_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:cron_jobs, [:domain_id])

    create table(:ftp_accounts) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :username, :string, null: false
      add :hashed_password, :string, null: false
      add :home_dir, :string
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ftp_accounts, [:username])
    create index(:ftp_accounts, [:domain_id])
  end
end
