defmodule Hostctl.Hosting.DomainS3Backend do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "domain_s3_backends" do
    field :endpoint_url, :string
    field :bucket, :string
    field :path_prefix, :string, default: ""
    field :enabled, :boolean, default: true

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(s3_backend, attrs) do
    s3_backend
    |> cast(attrs, [:endpoint_url, :bucket, :path_prefix, :enabled, :domain_id])
    |> validate_required([:endpoint_url, :bucket, :domain_id])
    |> validate_format(:endpoint_url, ~r|^https?://[^\s/$.?#].[^\s]*$|,
      message: "must be a valid URL (e.g. https://s3.amazonaws.com)"
    )
    |> validate_format(:bucket, ~r/^[a-z0-9][a-z0-9\-\.]{1,61}[a-z0-9]$/,
      message: "must be a valid S3 bucket name"
    )
    |> update_change(:endpoint_url, &String.trim_trailing(&1, "/"))
    |> update_change(:path_prefix, &normalize_prefix/1)
    |> foreign_key_constraint(:domain_id)
    |> unique_constraint(:domain_id, name: :domain_s3_backends_domain_id_index)
  end

  defp normalize_prefix(nil), do: ""

  defp normalize_prefix(prefix) when is_binary(prefix) do
    prefix
    |> String.trim()
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
  end
end
