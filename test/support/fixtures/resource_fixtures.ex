defmodule Hostctl.ResourceFixtures do
  import ExUnit.Callbacks
  import Hostctl.AccountsFixtures
  alias Hostctl.{Repo, Resources}
  alias Hostctl.Hosting.Domain
  alias Hostctl.Isolation.SystemIdentity

  def resource_fixture do
    previous = Application.get_env(:hostctl, :resource_process_reader)
    Application.put_env(:hostctl, :resource_process_reader, Resources.TestProcessReader)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:hostctl, :resource_process_reader, previous),
        else: Application.delete_env(:hostctl, :resource_process_reader)
    end)

    start_supervised!(%{
      id: Resources.TestProcessReader,
      start: {Agent, :start_link, [fn -> {:ok, []} end, [name: Resources.TestProcessReader]]}
    })

    admin = admin_user_fixture()
    owner = user_fixture() |> Ecto.Changeset.change(name: "Cedar Hosting") |> Repo.update!()
    peer = user_fixture() |> Ecto.Changeset.change(name: "Maple Studio") |> Repo.update!()

    identity =
      Repo.insert!(%SystemIdentity{
        user_id: owner.id,
        original_user_id: owner.id,
        username: "hc_#{owner.id}",
        uid: 12001,
        gid: 12001,
        state: :ready
      })

    peer_identity =
      Repo.insert!(%SystemIdentity{
        user_id: peer.id,
        original_user_id: peer.id,
        username: "hc_#{peer.id}",
        uid: 12002,
        gid: 12002,
        state: :ready
      })

    Repo.insert!(%Domain{user_id: owner.id, name: "cedar.example"})
    Repo.insert!(%Domain{user_id: owner.id, name: "shop.cedar.example"})
    Repo.insert!(%Domain{user_id: peer.id, name: "maple.example"})

    processes = [
      process(410, identity, 96.4, "php-fpm8.5"),
      process(420, peer_identity, 4.2, "php-fpm8.5"),
      %{id: 1, pid: 1, uid: 0, linux_user: "root", cpu: 0.1, rss_kb: 18000, command: "systemd"}
    ]

    set_processes({:ok, processes})
    %{admin: admin, owner: owner, peer: peer, identity: identity, processes: processes}
  end

  def set_processes(value), do: Agent.update(Resources.TestProcessReader, fn _ -> value end)

  defp process(pid, identity, cpu, command),
    do: %{
      id: pid,
      pid: pid,
      uid: identity.uid,
      linux_user: identity.username,
      cpu: cpu,
      rss_kb: 262_144,
      command: command
    }
end
