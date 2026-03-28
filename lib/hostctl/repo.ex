defmodule Hostctl.Repo do
  use Ecto.Repo,
    otp_app: :hostctl,
    adapter: Ecto.Adapters.Postgres
end
