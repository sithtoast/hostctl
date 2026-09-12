defmodule Hostctl.Resources.CLI do
  @moduledoc "Local operator lookup using repository access only; no hosting workers are started."
  alias Hostctl.Accounts.{Scope, User}
  alias Hostctl.{Repo, Resources}

  def lookup(kind, value) do
    with {:ok, kind, value} <- parse(kind, value) do
      Application.ensure_all_started(:ssl)
      Application.ensure_loaded(:hostctl)
      scope = Scope.for_user(%User{role: "admin"})

      case Ecto.Migrator.with_repo(Repo, fn _ -> Resources.lookup(scope, kind, value) end) do
        {:ok, result, _} -> result
        _ -> {:error, :repository_unavailable}
      end
    end
  end

  def run(kind, value) do
    previous = Logger.get_process_level(self())
    Logger.put_process_level(self(), :warning)

    try do
      case lookup(kind, value) do
        {:ok, result} ->
          IO.puts(Jason.encode!(result, pretty: true))

        {:error, reason} ->
          IO.puts(:stderr, "Account lookup failed: #{reason}")
          System.halt(1)
      end
    after
      if previous,
        do: Logger.put_process_level(self(), previous),
        else: Logger.delete_process_level(self())
    end
  end

  @doc false
  def parse("username", value) when is_binary(value) and byte_size(value) in 1..32,
    do: {:ok, :username, value}

  def parse(kind, value) when kind in ["pid", "uid"] and is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 and (kind == "uid" or number > 0) ->
        {:ok, if(kind == "pid", do: :pid, else: :uid), number}

      _ ->
        {:error, :invalid_lookup}
    end
  end

  def parse(_, _), do: {:error, :invalid_lookup}
end
