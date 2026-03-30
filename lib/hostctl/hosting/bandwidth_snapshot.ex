defmodule Hostctl.Hosting.BandwidthSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "domain_bandwidth_snapshots" do
    field :year, :integer
    field :month, :integer
    field :mb_used, :integer, default: 0

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:year, :month, :mb_used, :domain_id])
    |> validate_required([:year, :month, :domain_id])
    |> validate_number(:year, greater_than: 2000)
    |> validate_number(:month, greater_than_or_equal_to: 1, less_than_or_equal_to: 12)
    |> validate_number(:mb_used, greater_than_or_equal_to: 0)
    |> unique_constraint([:domain_id, :year, :month])
  end
end
