defmodule Hostctl.Hosting.DomainSmarthostSetting do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "domain_smarthost_settings" do
    field :enabled, :boolean, default: false
    field :host, :string
    field :port, :integer, default: 587
    field :auth_required, :boolean, default: true
    field :username, :string
    field :password, :string

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:enabled, :host, :port, :auth_required, :username, :password])
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65535)
    |> validate_when_enabled()
  end

  defp validate_when_enabled(changeset) do
    if get_field(changeset, :enabled) do
      changeset
      |> validate_required([:host, :port])
      |> validate_auth_fields()
    else
      changeset
    end
  end

  defp validate_auth_fields(changeset) do
    if get_field(changeset, :auth_required) do
      validate_required(changeset, [:username, :password])
    else
      changeset
    end
  end
end
