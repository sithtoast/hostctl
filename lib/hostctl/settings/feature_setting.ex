defmodule Hostctl.Settings.FeatureSetting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "feature_settings" do
    field :key, :string
    field :enabled, :boolean, default: false
    field :status, :string, default: "not_installed"
    field :status_message, :string

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(not_installed installing installed failed)

  def changeset(feature, attrs) do
    feature
    |> cast(attrs, [:key, :enabled, :status, :status_message])
    |> validate_required([:key])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:key)
  end
end
