defmodule Hostctl.Resources do
  @moduledoc "Read-only process attribution for server administrators."
  import Ecto.Query
  alias Hostctl.Accounts.{Scope, User}
  alias Hostctl.Hosting.Domain
  alias Hostctl.Isolation.SystemIdentity
  alias Hostctl.Repo

  @limit 500

  def snapshot(scope, query \\ "")

  def snapshot(%Scope{user: %User{role: "admin"}}, query) do
    with {:ok, processes} <- reader().snapshot() do
      identities = identity_rows()
      by_uid = Map.new(Enum.reject(identities, &is_nil(&1.uid)), &{&1.uid, &1})
      attributed = Enum.map(processes, &attribute(&1, by_uid))
      query = query |> String.slice(0, 120) |> String.trim() |> String.downcase()
      filtered = Enum.filter(attributed, &matches?(&1, query))

      {:ok,
       %{
         sampled_at: DateTime.utc_now(:second),
         total: length(attributed),
         attributed: Enum.count(attributed, &(&1.attribution == :account)),
         matching: length(filtered),
         limit: @limit,
         processes: filtered |> Enum.sort_by(&{-&1.cpu, -&1.rss_kb, &1.pid}) |> Enum.take(@limit)
       }}
    end
  end

  def snapshot(_, _), do: {:error, :forbidden}

  def lookup(%Scope{user: %User{role: "admin"}}, kind, value) when kind in [:uid, :username] do
    with :ok <- validate_lookup(kind, value) do
      match = Enum.find(identity_rows(), &(Map.fetch!(&1, kind) == value))
      if match, do: {:ok, match}, else: {:error, :identity_not_found}
    end
  end

  def lookup(%Scope{user: %User{role: "admin"}}, :pid, pid) when is_integer(pid) and pid > 0 do
    with {:ok, processes} <- reader().snapshot(),
         process when not is_nil(process) <- Enum.find(processes, &(&1.pid == pid)) do
      by_uid = Map.new(Enum.reject(identity_rows(), &is_nil(&1.uid)), &{&1.uid, &1})
      {:ok, attribute(process, by_uid)}
    else
      nil -> {:error, :process_not_found}
      error -> error
    end
  end

  def lookup(%Scope{user: %User{role: "admin"}}, _, _), do: {:error, :invalid_lookup}
  def lookup(_, _, _), do: {:error, :forbidden}

  defp validate_lookup(:uid, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_lookup(:username, value) when is_binary(value) and byte_size(value) in 1..32,
    do: :ok

  defp validate_lookup(_, _), do: {:error, :invalid_lookup}

  defp reader,
    do: Application.get_env(:hostctl, :resource_process_reader, Hostctl.Resources.ProcessReader)

  defp identity_rows do
    domains =
      Repo.all(from d in Domain, order_by: d.name, select: {d.user_id, d.name})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Repo.all(
      from i in SystemIdentity,
        left_join: u in User,
        on: u.id == i.user_id,
        select: %{
          id: i.id,
          user_id: i.user_id,
          original_user_id: i.original_user_id,
          username: i.username,
          uid: i.uid,
          gid: i.gid,
          state: i.state,
          name: u.name,
          email: u.email
        }
    )
    |> Enum.map(fn identity ->
      Map.put(identity, :domains, Map.get(domains, identity.user_id, []))
    end)
  end

  defp attribute(process, identities) do
    identity = Map.get(identities, process.uid)

    cond do
      identity && identity.username != process.linux_user ->
        Map.merge(process, %{attribution: :identity_mismatch, owner: nil})

      identity ->
        Map.merge(process, %{attribution: :account, owner: identity})

      true ->
        Map.merge(process, %{attribution: :shared, owner: nil})
    end
  end

  defp matches?(_process, ""), do: true

  defp matches?(process, query) do
    owner = process.owner

    fields =
      [process.pid, process.uid, process.linux_user, process.command] ++
        if(owner, do: [owner.name, owner.email, owner.original_user_id | owner.domains], else: [])

    Enum.any?(fields, &String.contains?(String.downcase(to_string(&1)), query))
  end
end
