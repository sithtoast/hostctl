defmodule Mix.Tasks.Hostctl.Account.Owner do
  use Mix.Task
  @shortdoc "Look up a hosting owner by Linux username, UID or PID"
  @moduledoc """
  Read-only local operator lookup (requires database access):

      mix hostctl.account.owner --user hc_5
      mix hostctl.account.owner --uid 1005
      mix hostctl.account.owner --pid 1234

  Starts only the repository, not hosting workers. PID lookup requires Linux.
  Release installs provide `sudo /opt/hostctl/bin/account-owner` with the same options.
  """
  def run([flag, value]) when flag in ["--user", "--uid", "--pid"] do
    kind = if flag == "--user", do: "username", else: String.trim_leading(flag, "--")

    case Hostctl.Resources.CLI.parse(kind, value) do
      {:ok, _, _} ->
        Mix.Task.run("app.config")
        Hostctl.Resources.CLI.run(kind, value)

      _ ->
        Mix.raise("Expected a valid Linux username, UID or positive PID")
    end
  end

  def run(_),
    do: Mix.raise("Usage: mix hostctl.account.owner --user USERNAME | --uid UID | --pid PID")
end
