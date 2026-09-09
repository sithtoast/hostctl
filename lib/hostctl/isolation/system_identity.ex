defmodule Hostctl.Isolation.SystemIdentity do
  @moduledoc """
  A durable account identity reservation, separate from a panel login.

  Pending reservations do not imply that a Linux user exists or that any hosted
  service is isolated. Numeric IDs will be recorded by the Linux provisioner.
  Records survive owner deletion so retained ownership cannot be silently reused.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Accounts.User

  schema "account_system_identities" do
    belongs_to :user, User
    field :original_user_id, :integer
    field :username, :string
    field :uid, :integer
    field :gid, :integer

    field :state, Ecto.Enum,
      values: [:pending, :provisioning, :provisioned, :migrating, :ready, :failed, :retired],
      default: :pending

    timestamps(type: :utc_datetime)
  end

  @doc false
  def reservation_changeset(%User{id: id}) when is_integer(id) and id > 0 do
    %__MODULE__{user_id: id, original_user_id: id, username: username(id)}
    |> change()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
    |> unique_constraint(:original_user_id)
    |> unique_constraint(:username)
    |> check_constraint(:user_id, name: :identity_owner)
  end

  def username(id) when is_integer(id) and id > 0, do: "hc_#{id}"
end
