defmodule Hostctl.Settings do
  @moduledoc """
  Context for server-level panel settings (admin only).
  """

  import Ecto.Query
  alias Hostctl.Repo
  alias Hostctl.Settings.ServerIpSetting

  # ---------------------------------------------------------------------------
  # Network interface detection
  # ---------------------------------------------------------------------------

  @doc """
  Returns a list of IP addresses detected on local network interfaces,
  excluding loopback addresses.
  """
  def detect_server_ips do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        for {iface_charlist, opts} <- interfaces,
            addr <- Keyword.get_values(opts, :addr),
            tuple_size(addr) in [4, 8],
            not loopback?(addr) do
          %{
            interface: to_string(iface_charlist),
            ip_address: format_ip(addr)
          }
        end

      {:error, _} ->
        []
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.downcase/1)
    |> Enum.join(":")
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  @doc """
  Syncs detected IPs into the database: inserts new ones, leaves existing ones alone,
  and returns the full list of persisted records merged with current detection.
  """
  def sync_and_list_ip_settings do
    detected = detect_server_ips()
    detected_addresses = Enum.map(detected, & &1.ip_address)

    existing =
      Repo.all(
        from s in ServerIpSetting,
          where: s.ip_address in ^detected_addresses
      )

    existing_addresses = MapSet.new(existing, & &1.ip_address)

    new_ips =
      detected
      |> Enum.reject(&MapSet.member?(existing_addresses, &1.ip_address))
      |> Enum.map(fn %{ip_address: ip, interface: iface} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        %{
          ip_address: ip,
          interface: iface,
          external_ip: nil,
          label: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    unless new_ips == [] do
      Repo.insert_all(ServerIpSetting, new_ips, on_conflict: :nothing)
    end

    Repo.all(
      from s in ServerIpSetting,
        where: s.ip_address in ^detected_addresses,
        order_by: [asc: s.inserted_at]
    )
  end

  @doc "Returns all persisted IP settings (even ones no longer detected)."
  def list_ip_settings do
    Repo.all(from s in ServerIpSetting, order_by: [asc: s.inserted_at])
  end

  @doc "Gets a single IP setting by id, raises if not found."
  def get_ip_setting!(id), do: Repo.get!(ServerIpSetting, id)

  @doc "Updates the external_ip and label for an IP setting."
  def update_ip_setting(%ServerIpSetting{} = setting, attrs) do
    setting
    |> ServerIpSetting.changeset(attrs)
    |> Repo.update()
  end

  @doc "Returns a changeset for an IP setting."
  def change_ip_setting(%ServerIpSetting{} = setting, attrs \\ %{}) do
    ServerIpSetting.changeset(setting, attrs)
  end
end
