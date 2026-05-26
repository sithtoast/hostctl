defmodule Hostctl.Hosting.UploadJob do
  @moduledoc """
  Schema for tracking background S3 upload jobs with resume capability.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain
  alias Hostctl.Accounts.User
  alias Hostctl.EncryptedField

  @type t :: %__MODULE__{}

  schema "upload_jobs" do
    field :status, :string, default: "pending"
    field :job_type, :string
    field :source_path, :string
    field :s3_endpoint, :string
    field :s3_bucket, :string
    field :s3_prefix, :string
    field :s3_region, :string, default: "us-east-1"
    field :s3_access_key_id, :string
    field :s3_secret_access_key, EncryptedField
    field :total_files, :integer, default: 0
    field :uploaded_files, :integer, default: 0
    field :failed_files, :integer, default: 0
    field :current_file, :string
    field :error_message, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :domain, Domain
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(upload_job, attrs) do
    upload_job
    |> cast(attrs, [
      :domain_id,
      :user_id,
      :status,
      :job_type,
      :source_path,
      :s3_endpoint,
      :s3_bucket,
      :s3_prefix,
      :s3_region,
      :s3_access_key_id,
      :s3_secret_access_key,
      :total_files,
      :uploaded_files,
      :failed_files,
      :current_file,
      :error_message,
      :started_at,
      :completed_at,
      :metadata
    ])
    |> validate_required([
      :domain_id,
      :user_id,
      :job_type,
      :source_path,
      :s3_endpoint,
      :s3_bucket,
      :s3_access_key_id,
      :s3_secret_access_key
    ])
    |> validate_inclusion(:status, ["pending", "running", "completed", "failed", "paused"])
    |> foreign_key_constraint(:domain_id)
    |> foreign_key_constraint(:user_id)
  end
end
