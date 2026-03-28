defmodule Hostctl.Hosting.DbUser do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Database

  schema "db_users" do
    field :username, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true

    belongs_to :database, Database

    timestamps(type: :utc_datetime)
  end

  def changeset(db_user, attrs) do
    db_user
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
    |> validate_format(:username, ~r/^[a-z0-9_]+$/i,
      message: "must contain only letters, numbers, and underscores"
    )
    |> validate_length(:username, max: 32)
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:username, name: :db_users_database_id_username_index)
    |> put_hashed_password()
  end

  defp put_hashed_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(password))
    end
  end
end
