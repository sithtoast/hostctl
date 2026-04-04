defmodule Hostctl.Plesk.Migration do
  use Ecto.Schema
  import Ecto.Changeset

  schema "plesk_migrations" do
    field :name, :string
    field :source, :string
    field :status, :string, default: "discovered"
    field :source_params, :map, default: %{}
    field :subscriptions, {:array, :map}, default: []
    field :inventory, :map, default: %{}
    field :domain_configs, :map, default: %{}
    field :restore_results, :map, default: %{}
    field :server_credentials, :map, default: %{}

    belongs_to :user, Hostctl.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(migration, attrs) do
    migration
    |> cast(attrs, [
      :name,
      :source,
      :status,
      :source_params,
      :subscriptions,
      :inventory,
      :domain_configs,
      :restore_results,
      :server_credentials
    ])
    |> validate_required([:name, :source, :status])
    |> validate_inclusion(:source, ~w(backup api ssh))
    |> validate_inclusion(:status, ~w(discovered in_progress completed partial))
  end
end
