defmodule Hostctl.SpamProtection.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "spam_settings" do
    field :enabled, :boolean, default: false
    field :learning, :boolean, default: true
    field :junk_score, :integer, default: 6
    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:enabled, :learning, :junk_score])
    |> validate_required([:enabled, :learning, :junk_score])
    |> validate_number(:junk_score, greater_than_or_equal_to: 1, less_than_or_equal_to: 20)
  end
end
