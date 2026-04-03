defmodule Hostctl.Plesk do
  @moduledoc """
  Context for managing Plesk migrations (saved discovery + restore state).
  """

  import Ecto.Query

  alias Hostctl.Accounts.Scope
  alias Hostctl.Plesk.Migration
  alias Hostctl.Repo

  def list_migrations(%Scope{user: user}) do
    Migration
    |> where(user_id: ^user.id)
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  def get_migration!(%Scope{user: user}, id) do
    Migration
    |> where(user_id: ^user.id)
    |> Repo.get!(id)
  end

  def create_migration(%Scope{user: user}, attrs) do
    %Migration{user_id: user.id}
    |> Migration.changeset(attrs)
    |> Repo.insert()
  end

  def update_migration(%Migration{} = migration, attrs) do
    migration
    |> Migration.changeset(attrs)
    |> Repo.update()
  end

  def delete_migration(%Migration{} = migration) do
    Repo.delete(migration)
  end
end
