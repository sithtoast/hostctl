defmodule Hostctl.Hosting.DomainProxy do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "domain_proxies" do
    field :websocket_enabled, :boolean, default: true
    field :subdomain, :string, default: ""
    field :upstream_scheme, :string, default: "http"
    field :path, :string
    field :container_name, :string
    field :upstream_port, :integer
    field :enabled, :boolean, default: true

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(proxy, attrs) do
    proxy
    |> cast(attrs, [
      :path,
      :subdomain,
      :upstream_scheme,
      :websocket_enabled,
      :container_name,
      :upstream_port,
      :enabled
    ])
    |> update_change(:subdomain, &normalize_subdomain/1)
    |> validate_format(:subdomain, ~r/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)?\z/,
      message: "must be one subdomain label, such as app, or blank for the domain"
    )
    |> validate_exclusion(:subdomain, ["www"], message: "is already served by the main domain")
    |> validate_inclusion(:upstream_scheme, ["http", "https"])
    |> update_change(:path, &normalize_path/1)
    |> validate_required([
      :domain_id,
      :path,
      :container_name,
      :upstream_port,
      :upstream_scheme,
      :websocket_enabled,
      :enabled
    ])
    |> validate_format(:path, ~r|^/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*$|,
      message: "must be a valid URL path"
    )
    |> validate_format(:container_name, ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/,
      message: "must be a valid Docker container name"
    )
    |> validate_number(:upstream_port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> foreign_key_constraint(:domain_id)
    |> unique_constraint(:path, name: :domain_proxies_domain_id_subdomain_path_index)
  end

  def hostname(%__MODULE__{subdomain: subdomain, domain: domain}) do
    if subdomain in [nil, ""], do: domain.name, else: "#{subdomain}.#{domain.name}"
  end

  defp normalize_subdomain(nil), do: ""
  defp normalize_subdomain(value), do: value |> String.trim() |> String.downcase()

  defp normalize_path(path) when is_binary(path) do
    normalized =
      path
      |> String.trim()
      |> String.replace(~r{/+}, "/")
      |> ensure_leading_slash()

    if normalized != "/" do
      String.trim_trailing(normalized, "/")
    else
      normalized
    end
  end

  defp normalize_path(path), do: path

  defp ensure_leading_slash(""), do: "/"
  defp ensure_leading_slash("/" <> _rest = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path
end
