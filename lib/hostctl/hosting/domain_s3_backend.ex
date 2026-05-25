defmodule Hostctl.Hosting.DomainS3Backend do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.EncryptedField
  alias Hostctl.Hosting.Domain

  schema "domain_s3_backends" do
    field :endpoint_url, :string
    field :bucket, :string
    field :path_prefix, :string, default: ""
    field :region, :string, default: "us-east-1"
    field :enabled, :boolean, default: true
    field :access_key_id, :string
    field :secret_access_key, EncryptedField
    # Scope fields — both empty = whole domain.
    # subdomain non-empty = applies to that subdomain (e.g. "static" → static.example.com).
    # url_path non-empty = only serves requests under that URL path (e.g. "/assets").
    field :subdomain, :string, default: ""
    field :url_path, :string, default: ""
    # When true, hostctl provisions a rclone FUSE mount at the document root
    # for this scope so FTP users can upload directly to S3.
    field :ftp_mount_enabled, :boolean, default: false
    # When true, requests to "directory" paths (trailing slash) return an HTML
    # listing of objects at that S3 prefix instead of a 404.
    field :directory_listing, :boolean, default: false

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(s3_backend, attrs) do
    s3_backend
    |> cast(attrs, [
      :endpoint_url,
      :bucket,
      :path_prefix,
      :region,
      :enabled,
      :ftp_mount_enabled,
      :directory_listing,
      :access_key_id,
      :secret_access_key,
      :subdomain,
      :url_path,
      :domain_id
    ])
    |> validate_required([:endpoint_url, :bucket, :domain_id])
    |> validate_format(:url_path, ~r/^(\/[^\s]*)?$/, message: "must start with / or be empty")
    |> update_change(:subdomain, &String.trim/1)
    |> update_change(:url_path, &normalize_url_path/1)
    |> validate_format(:endpoint_url, ~r|^https?://[^\s/$.?#].[^\s]*$|,
      message: "must be a valid URL (e.g. https://s3.amazonaws.com)"
    )
    |> validate_format(:bucket, ~r/^[a-z0-9][a-z0-9\-\.]{1,61}[a-z0-9]$/,
      message: "must be a valid S3 bucket name"
    )
    |> update_change(:endpoint_url, &String.trim_trailing(&1, "/"))
    |> update_change(:path_prefix, &normalize_prefix/1)
    |> maybe_keep_secret_access_key(s3_backend)
    |> foreign_key_constraint(:domain_id)
    |> unique_constraint(:url_path,
      name: :domain_s3_backends_domain_id_subdomain_url_path_index,
      message: "an S3 backend with this scope already exists for this domain"
    )
  end

  # If a blank secret_access_key is submitted (e.g. the password field was left
  # empty on the form), preserve the existing encrypted value rather than
  # overwriting it with an empty string.
  defp maybe_keep_secret_access_key(changeset, existing) do
    case get_change(changeset, :secret_access_key) do
      nil -> changeset
      "" -> delete_change(changeset, :secret_access_key)
      _ -> changeset
    end
    |> then(fn cs ->
      if get_field(cs, :secret_access_key) == nil && existing.secret_access_key != nil do
        force_change(cs, :secret_access_key, existing.secret_access_key)
      else
        cs
      end
    end)
  end

  # Normalise url_path: ensure it starts with "/" and has no trailing slash.
  defp normalize_url_path(nil), do: ""

  defp normalize_url_path(path) when is_binary(path) do
    path = String.trim(path)

    cond do
      path == "" ->
        ""

      String.starts_with?(path, "/") ->
        String.trim_trailing(path, "/")

      true ->
        "/" <> String.trim_trailing(path, "/")
    end
  end

  defp normalize_prefix(nil), do: ""

  defp normalize_prefix(prefix) when is_binary(prefix) do
    prefix
    |> String.trim()
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
  end
end
