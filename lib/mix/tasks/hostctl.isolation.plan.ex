defmodule Mix.Tasks.Hostctl.Isolation.Plan do
  use Mix.Task

  alias Hostctl.Accounts.{Scope, User}
  alias Hostctl.{Isolation, Repo}

  @shortdoc "Inventory an account before migrating to a dedicated system identity"
  @moduledoc """
  Prints a credential-free JSON database inventory for one hosting owner.

      mix hostctl.isolation.plan --user-id 123
      mix hostctl.isolation.plan --user-id 123 --reserve

  The default is read-only. `--reserve` creates an idempotent pending identity
  reservation in the database. Neither mode creates Linux users or changes
  ownership, PHP, FTP, mounts, or service configuration. There is no apply mode.

  Run database migrations first, using the intended environment's configuration.
  This is a local operator command with database access; it accepts a hosting
  owner's ID, not the ID of a manager acting on their behalf. It starts the Repo
  only, avoiding web/backup/upload workers and their startup side effects.

  The report is a database preflight, not a live filesystem safety check. Its
  findings must be resolved and the required live checks completed before a
  future service migration can proceed.
  """

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [user_id: [:integer, :keep], reserve: :boolean])

    id = opts[:user_id]

    unless invalid == [] and positional == [] and is_integer(id) and id > 0 and
             length(Keyword.get_values(opts, :user_id)) == 1 do
      Mix.raise("Usage: mix hostctl.isolation.plan --user-id POSITIVE_ID [--reserve]")
    end

    Mix.Task.run("app.config")

    # Keep SQL debug output out of the JSON report without changing the logging
    # policy of other processes when invoked from an already-running application.
    previous_level = Logger.get_process_level(self())
    Logger.put_process_level(self(), :warning)

    try do
      case Ecto.Migrator.with_repo(Repo, fn _repo -> report(id, opts[:reserve] == true) end) do
        {:ok, report, _apps} -> Mix.shell().info(Jason.encode!(report, pretty: true))
        {:error, _reason} -> Mix.raise("Could not start the Hostctl repository")
      end
    after
      if previous_level do
        Logger.put_process_level(self(), previous_level)
      else
        Logger.delete_process_level(self())
      end
    end
  end

  defp report(id, reserve?) do
    scope = Scope.for_user(%User{id: id})

    if reserve? do
      case Isolation.reserve_identity(scope) do
        {:ok, _identity} ->
          :ok

        {:error, :account_not_found} ->
          Mix.raise("Hosting owner not found")

        {:error, :no_hosting_resources} ->
          Mix.raise("Owner has no domains or FTP accounts")

        {:error, :identity_retained} ->
          Mix.raise("A retained identity already reserves this owner ID")

        {:error, _changeset} ->
          Mix.raise("Could not reserve account identity")
      end
    end

    case Isolation.plan(scope) do
      {:ok, plan} -> plan
      {:error, :account_not_found} -> Mix.raise("Hosting owner not found")
    end
  end
end
