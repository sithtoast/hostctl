defmodule Hostctl.Hosting.CronJob do
  use Ecto.Schema
  import Ecto.Changeset

  alias Hostctl.Hosting.Domain

  schema "cron_jobs" do
    field :schedule, :string
    field :command, :string
    field :enabled, :boolean, default: true
    field :last_run_at, :utc_datetime

    belongs_to :domain, Domain

    timestamps(type: :utc_datetime)
  end

  @cron_pattern ~r/^(\*|[0-9,\-\/]+)\s+(\*|[0-9,\-\/]+)\s+(\*|[0-9,\-\/]+)\s+(\*|[0-9,\-\/]+)\s+(\*|[0-9,\-\/]+)$/

  def changeset(cron_job, attrs) do
    cron_job
    |> cast(attrs, [:schedule, :command, :enabled])
    |> validate_required([:schedule, :command])
    |> validate_format(:schedule, @cron_pattern,
      message: "must be a valid cron expression (e.g. * * * * *)"
    )
    |> validate_length(:command, max: 512)
  end
end
