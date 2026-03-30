defmodule Hostctl.Backup.Log do
  use Ecto.Schema
  import Ecto.Changeset

  schema "backup_logs" do
    field :status, :string, default: "pending"
    field :trigger, :string, default: "manual"
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :file_size_bytes, :integer
    field :destination, :string
    field :local_path, :string
    field :s3_key, :string
    field :details, :map, default: %{}
    field :error_message, :string

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(pending running success failed)
  @valid_triggers ~w(manual scheduled manual_domain)

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :status,
      :trigger,
      :started_at,
      :completed_at,
      :file_size_bytes,
      :destination,
      :local_path,
      :s3_key,
      :details,
      :error_message
    ])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:trigger, @valid_triggers)
  end
end
