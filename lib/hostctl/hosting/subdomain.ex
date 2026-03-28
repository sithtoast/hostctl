defmodule Hostctl.Hosting.Subdomain do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "subdomains" do
    field :name, :string
    field :document_root, :string
    field :status, :string, default: "active"

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(subdomain, attrs) do
    subdomain
    |> cast(attrs, [:name, :document_root, :status])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$/i,
      message: "must contain only letters, numbers, and hyphens"
    )
    |> validate_inclusion(:status, ~w(active suspended))
    |> unique_constraint(:name, name: :subdomains_domain_id_name_index)
  end
end
