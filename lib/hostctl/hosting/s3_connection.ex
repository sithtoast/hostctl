defmodule Hostctl.Hosting.S3Connection do
  use Ecto.Schema
  import Ecto.Changeset

  schema "s3_connections" do
    field :name, :string
    field :endpoint_url, :string
    field :region, :string, default: "us-east-1"
    field :access_key_id, :string, redact: true
    field :secret_access_key, Hostctl.EncryptedField, redact: true
    belongs_to :user, Hostctl.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:name, :endpoint_url, :region, :access_key_id, :secret_access_key])
    |> update_change(:endpoint_url, &Hostctl.S3Client.normalize_endpoint_change/1)
    |> validate_required([:name, :endpoint_url, :region, :access_key_id, :secret_access_key])
    |> validate_length(:name, max: 120)
    |> validate_change(:endpoint_url, fn :endpoint_url, value ->
      case Hostctl.S3Client.normalize_endpoint(value) do
        {:ok, _} -> []
        {:error, reason} -> [endpoint_url: reason]
      end
    end)
    |> unique_constraint([:user_id, :name])
  end
end
