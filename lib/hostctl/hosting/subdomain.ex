defmodule Hostctl.Hosting.Subdomain do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "subdomains" do
    field :name, :string
    field :document_root, :string
    field :status, :string, default: "active"
    field :domain_name, :string, virtual: true

    belongs_to :domain, Domain
    has_one :backup_setting, Hostctl.Backup.SubdomainSetting

    timestamps(type: :utc_datetime)
  end

  def changeset(subdomain, attrs) do
    subdomain
    |> cast(attrs, [:name, :document_root, :status, :domain_name])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$/i,
      message: "must contain only letters, numbers, and hyphens"
    )
    |> maybe_set_document_root()
    |> validate_inclusion(:status, ~w(active suspended))
    |> unique_constraint(:name, name: :subdomains_domain_id_name_index)
  end

  defp maybe_set_document_root(changeset) do
    subdomain_name = get_field(changeset, :name)
    domain_name = get_field(changeset, :domain_name)
    doc_root = get_field(changeset, :document_root)

    auto_generated? =
      is_nil(doc_root) or doc_root == "" or
        Regex.match?(~r|^/var/www/[^/]+/[^/]+/public$|, doc_root)

    if is_binary(subdomain_name) and subdomain_name != "" and
         is_binary(domain_name) and domain_name != "" and auto_generated? do
      put_change(changeset, :document_root, "/var/www/#{domain_name}/#{subdomain_name}/public")
    else
      changeset
    end
  end
end
