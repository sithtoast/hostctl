defmodule Hostctl.S3Connections do
  import Ecto.Query
  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting.S3Connection
  alias Hostctl.Repo

  def list(%Scope{user: user}) do
    Repo.all(from c in S3Connection, where: c.user_id == ^user.id, order_by: c.name)
  end

  def get(%Scope{user: user}, id) do
    with {id, ""} <- Integer.parse(to_string(id)) do
      Repo.one(from c in S3Connection, where: c.user_id == ^user.id and c.id == ^id)
    else
      _ -> nil
    end
  end

  def save(%Scope{user: user}, attrs) do
    %S3Connection{user_id: user.id}
    |> S3Connection.changeset(attrs)
    |> Repo.insert(log: false)
  end
end
