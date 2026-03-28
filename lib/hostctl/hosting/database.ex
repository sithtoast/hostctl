defmodule Hostctl.Hosting.Database do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.{Domain, DbUser}

  schema "databases" do
    field :name, :string
    field :db_type, :string, default: "postgresql"
    field :status, :string, default: "active"

    belongs_to :domain, Domain
    has_many :db_users, DbUser

    timestamps(type: :utc_datetime)
  end

  def changeset(database, attrs) do
    database
    |> cast(attrs, [:name, :db_type, :status])
    |> validate_required([:name, :db_type])
    |> validate_format(:name, ~r/^[a-z0-9_]+$/i,
      message: "must contain only letters, numbers, and underscores"
    )
    |> validate_length(:name, max: 64)
    |> validate_inclusion(:db_type, ~w(postgresql mysql))
    |> validate_inclusion(:status, ~w(active suspended))
    |> unique_constraint(:name)
  end
end
