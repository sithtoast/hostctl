defmodule Hostctl.Repo.Migrations.CreateUploadJobs do
  use Ecto.Migration

  def change do
    create table(:upload_jobs) do
      add :domain_id, references(:domains, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :job_type, :string, null: false
      add :source_path, :string, null: false
      add :s3_endpoint, :string, null: false
      add :s3_bucket, :string, null: false
      add :s3_prefix, :string
      add :s3_region, :string, default: "us-east-1"
      add :s3_access_key_id, :string, null: false
      add :s3_secret_access_key, :binary, null: false
      add :total_files, :integer, default: 0
      add :uploaded_files, :integer, default: 0
      add :failed_files, :integer, default: 0
      add :current_file, :string
      add :error_message, :text
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:upload_jobs, [:domain_id])
    create index(:upload_jobs, [:user_id])
    create index(:upload_jobs, [:status])
  end
end
