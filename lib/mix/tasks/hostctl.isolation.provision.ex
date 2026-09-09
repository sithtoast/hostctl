defmodule Mix.Tasks.Hostctl.Isolation.Provision do
  use Mix.Task
  alias Hostctl.Accounts.{Scope, User}
  alias Hostctl.Isolation.Runtime
  alias Hostctl.Repo

  @shortdoc "Enroll an empty hosting account in Linux isolation"
  @moduledoc """
  Explicitly enrolls an owner before adding their first domain or FTP account.

      mix hostctl.isolation.provision --user-id 123

  Requires Linux, python3, acl, Nginx and Hostctl's normal privileged command
  access. Creates locked system identities and switches Nginx to hostctl-web,
  preserving access to legacy PHP sockets through its www-data supplementary
  group. Add domains and FTP accounts normally after enrollment succeeds.

  Existing accounts with hosting resources require a separate migration and are
  rejected before any OS changes. The default plan command remains read-only.
  Run migrations first. Starts only the repository, not application workers.
  """
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [user_id: [:integer, :keep]])
    id = opts[:user_id]

    unless rest == [] and invalid == [] and is_integer(id) and id > 0 and
             length(Keyword.get_values(opts, :user_id)) == 1 do
      Mix.raise("Usage: mix hostctl.isolation.provision --user-id POSITIVE_ID")
    end

    Mix.Task.run("app.config")

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Repo, fn _ ->
        Runtime.provision_identity(Scope.for_user(%User{id: id}))
      end)

    case result do
      {:ok, identity} ->
        Mix.shell().info(
          "Enrolled #{identity.username} (UID #{identity.uid}, GID #{identity.gid})."
        )

      {:error, reason} when is_atom(reason) ->
        Mix.raise("Isolation enrollment failed: #{reason}")

      {:error, _} ->
        Mix.raise("Isolation enrollment failed; check server configuration.")
    end
  end
end
