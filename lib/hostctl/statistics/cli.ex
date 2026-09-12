defmodule Hostctl.Statistics.CLI do
  @moduledoc "Statistics commands using repository access without starting hosting workers."
  alias Hostctl.Accounts.{Scope, User}

  def run(action, id, source) do
    with {id, ""} when id > 0 <- Integer.parse(id),
         true <- action in ["collect", "history"] do
      Application.ensure_all_started(:ssl)
      Application.ensure_loaded(:hostctl)
      scope = Scope.for_user(%User{role: "admin"})

      {:ok, result, _} =
        Ecto.Migrator.with_repo(Hostctl.Repo, fn _ ->
          if action == "history",
            do: Hostctl.Statistics.import_history(scope, id, source),
            else: Hostctl.Statistics.refresh(scope, id)
        end)

      case result do
        {:ok, report} ->
          IO.puts(Jason.encode!(report, pretty: true))

        {:error, reason} ->
          IO.puts(:stderr, reason)
          System.halt(1)
      end
    else
      _ -> raise ArgumentError, "Expected collect DOMAIN_ID or history DOMAIN_ID SOURCE_DIRECTORY"
    end
  end
end
