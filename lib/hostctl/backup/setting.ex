defmodule Hostctl.Backup.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "backup_settings" do
    field :local_enabled, :boolean, default: false
    field :local_path, :string, default: "/var/backups/hostctl"
    field :local_retention_days, :integer, default: 7

    field :s3_enabled, :boolean, default: false
    field :s3_endpoint, :string
    field :s3_region, :string, default: "us-east-1"
    field :s3_bucket, :string
    field :s3_access_key_id, :string
    field :s3_secret_access_key, :string
    field :s3_path_prefix, :string, default: "hostctl-backups"
    field :s3_retention_days, :integer, default: 30

    field :schedule_enabled, :boolean, default: false
    field :schedule_frequency, :string, default: "daily"
    field :schedule_hour, :integer, default: 2
    field :schedule_minute, :integer, default: 0
    field :schedule_day_of_week, :integer, default: 1

    field :backup_database, :boolean, default: true
    field :backup_mysql, :boolean, default: false
    field :backup_mail, :boolean, default: false
    field :backup_files, :boolean, default: false
    field :s3_mode, :string, default: "archive"

    timestamps(type: :utc_datetime)
  end

  @all_fields [
    :local_enabled,
    :local_path,
    :local_retention_days,
    :s3_enabled,
    :s3_endpoint,
    :s3_region,
    :s3_bucket,
    :s3_access_key_id,
    :s3_secret_access_key,
    :s3_path_prefix,
    :s3_retention_days,
    :schedule_enabled,
    :schedule_frequency,
    :schedule_hour,
    :schedule_minute,
    :schedule_day_of_week,
    :backup_database,
    :backup_mysql,
    :backup_mail,
    :backup_files,
    :s3_mode
  ]

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @all_fields)
    |> validate_required([
      :local_path,
      :local_retention_days,
      :s3_region,
      :s3_path_prefix,
      :s3_retention_days
    ])
    |> validate_number(:local_retention_days, greater_than: 0)
    |> validate_number(:s3_retention_days, greater_than: 0)
    |> validate_number(:schedule_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:schedule_minute, greater_than_or_equal_to: 0, less_than_or_equal_to: 59)
    |> validate_number(:schedule_day_of_week,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 7
    )
    |> validate_inclusion(:schedule_frequency, ["daily", "weekly"])
    |> validate_inclusion(:s3_mode, ["archive", "stream"])
    |> validate_s3_fields()
    |> validate_local_fields()
  end

  defp validate_s3_fields(changeset) do
    if get_field(changeset, :s3_enabled) do
      changeset
      |> validate_required([:s3_bucket, :s3_access_key_id, :s3_secret_access_key],
        message: "is required when S3 is enabled"
      )
    else
      changeset
    end
  end

  defp validate_local_fields(changeset) do
    if get_field(changeset, :local_enabled) do
      changeset
      |> validate_required([:local_path], message: "is required when local backup is enabled")
    else
      changeset
    end
  end
end
