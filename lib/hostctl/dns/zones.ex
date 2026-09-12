defmodule Hostctl.DNS.Zones do
  @moduledoc "Ownership-checked provider preferences and DigitalOcean zone operations."
  import Ecto.Query
  alias Hostctl.{Repo, Hosting, Settings}
  alias Hostctl.Hosting.{DnsZone, DnsRecord}
  alias Hostctl.DNS.{DigitalOcean, Record}

  def get!(scope, zone_id) do
    zone = Repo.get!(DnsZone, zone_id)

    if scope.user.role == "admin",
      do: Hosting.get_domain_for_admin!(zone.domain_id),
      else: Hosting.get_domain!(scope, zone.domain_id)

    zone
  end

  def save_provider(scope, zone_id, attrs) do
    zone = get!(scope, zone_id)
    cs = DnsZone.provider_changeset(zone, attrs)
    changed? = Enum.any?([:provider, :digitalocean_api_token], &Map.has_key?(cs.changes, &1))

    if cs.valid? and changed? do
      Repo.transaction(fn ->
        # Retire IDs with their credential/provider binding; never reuse across accounts.
        Repo.update_all(from(r in DnsRecord, where: r.dns_zone_id == ^zone.id),
          set: [digitalocean_record_id: nil, cloudflare_record_id: nil]
        )

        cs
        |> Ecto.Changeset.change(cloudflare_zone_id: nil, digitalocean_zone_name: nil)
        |> Repo.update!(log: false)
      end)
    else
      Repo.update(cs, log: false)
    end
  end

  def link(scope, zone_id) do
    zone = get!(scope, zone_id)

    with {:ok, token} <- token(zone),
         domain <- Repo.preload(zone, :domain).domain,
         {:ok, name} <- DigitalOcean.find_zone(token, domain.name) do
      zone |> Ecto.Changeset.change(digitalocean_zone_name: name) |> Repo.update()
    end
  end

  def unlink(scope, zone_id) do
    zone = get!(scope, zone_id)

    Repo.transaction(fn ->
      Repo.update_all(from(r in DnsRecord, where: r.dns_zone_id == ^zone.id),
        set: [digitalocean_record_id: nil]
      )

      zone |> Ecto.Changeset.change(digitalocean_zone_name: nil) |> Repo.update!(log: false)
    end)
  end

  def list(scope, zone_id) do
    zone = get!(scope, zone_id)

    with {:ok, token, name} <- connection(zone),
         {:ok, records} <- DigitalOcean.list_records(token, name) do
      {:ok, normalize(records, name)}
    end
  end

  def import_records(scope, zone_id) do
    zone = get!(scope, zone_id)

    with {:ok, records} <- list(scope, zone.id) do
      Repo.transaction(fn ->
        Enum.reduce(records, %{imported: 0, updated: 0, skipped: 0}, fn remote, acc ->
          if remote["type"] in DnsRecord.valid_types() do
            {value, priority} = Record.local_value(remote)

            attrs = %{
              type: remote["type"],
              name: remote["name"],
              value: value,
              priority: priority,
              ttl: remote["ttl"]
            }

            existing = Repo.all(from(r in DnsRecord, where: r.dns_zone_id == ^zone.id))

            record =
              Enum.find(existing, &(&1.digitalocean_record_id == remote["id"])) ||
                Enum.find(existing, fn r ->
                  is_nil(r.digitalocean_record_id) and
                    same?(r, remote, zone.digitalocean_zone_name)
                end)

            cs =
              DnsRecord.changeset(record || %DnsRecord{dns_zone_id: zone.id}, attrs)
              |> Ecto.Changeset.put_change(:digitalocean_record_id, remote["id"])

            key =
              cond do
                is_nil(record) -> :imported
                cs.changes == %{} -> :skipped
                true -> :updated
              end

            case Repo.insert_or_update(cs) do
              {:ok, _} -> Map.update!(acc, key, &(&1 + 1))
              {:error, cs} -> Repo.rollback(cs)
            end
          else
            Map.update!(acc, :skipped, &(&1 + 1))
          end
        end)
      end)
    end
  end

  def sync(scope, zone_id) do
    zone = get!(scope, zone_id)

    with {:ok, token, name} <- connection(zone),
         {:ok, remote} <- DigitalOcean.list_records(token, name) do
      records = Repo.all(from(r in DnsRecord, where: r.dns_zone_id == ^zone.id, order_by: r.id))

      {summary, _} =
        Enum.reduce(records, {%{synced: 0, failed: 0}, normalize(remote, name)}, fn r,
                                                                                    {acc, current} ->
          case upsert(token, name, r, current, records) do
            {:ok, id, updated} ->
              case Repo.update(Ecto.Changeset.change(r, digitalocean_record_id: id)) do
                {:ok, _} -> {Map.update!(acc, :synced, &(&1 + 1)), updated}
                {:error, _} -> {Map.update!(acc, :failed, &(&1 + 1)), updated}
              end

            {:error, _} ->
              {Map.update!(acc, :failed, &(&1 + 1)), current}
          end
        end)

      {:ok, summary}
    end
  end

  # Called for linked DigitalOcean records only. Keep failed writes visible as form errors.
  def persist(zone, changeset) do
    Repo.transaction(fn ->
      record =
        case Repo.insert_or_update(changeset) do
          {:ok, record} -> record
          {:error, cs} -> Repo.rollback(cs)
        end

      with {:ok, token, name} <- connection(zone),
           {:ok, remote} <- DigitalOcean.list_records(token, name),
           records <- Repo.all(from(r in DnsRecord, where: r.dns_zone_id == ^zone.id)),
           {:ok, id, _} <-
             upsert(
               token,
               name,
               record,
               normalize(remote, name),
               records,
               Map.has_key?(changeset.changes, :ttl)
             ),
           {:ok, record} <- Repo.update(Ecto.Changeset.change(record, digitalocean_record_id: id)) do
        record
      else
        {:error, reason} ->
          Repo.rollback(Ecto.Changeset.add_error(changeset, :value, error(reason)))
      end
    end)
  end

  def delete(zone, record) do
    with {:ok, token, name} <- connection(zone),
         {:ok, remote} <- DigitalOcean.list_records(token, name) do
      linked = Enum.find(normalize(remote, name), &(&1["id"] == record.digitalocean_record_id))

      peers =
        Repo.all(from(r in DnsRecord, where: r.dns_zone_id == ^zone.id and r.id != ^record.id))

      cond do
        is_nil(linked) ->
          Repo.delete(record)

        Enum.any?(peers, &(&1.digitalocean_record_id == record.digitalocean_record_id)) ->
          {:error, "This remote record is shared by multiple local rows; unlink or review first"}

        not same?(record, linked, name) ->
          {:error, "Remote record changed; refresh and import before deleting"}

        record.type == "NS" and Record.fqdn(record.name, name) == name ->
          {:error, "Authoritative nameserver deletion is disabled"}

        true ->
          with :ok <- DigitalOcean.delete_record(token, name, record.digitalocean_record_id),
               do: Repo.delete(record)
      end
    end
  end

  def linked?(zone),
    do:
      is_binary(zone.digitalocean_zone_name) and
        Settings.dns_setting_for_zone(zone).provider == "digitalocean"

  defp upsert(token, name, record, remote, records, update_ttl? \\ false) do
    exact = Enum.find(remote, &same?(record, &1, name))
    linked = Enum.find(remote, &(&1["id"] == record.digitalocean_record_id))

    cond do
      exact && update_ttl? && exact["id"] == record.digitalocean_record_id &&
          Enum.count(records, &(&1.digitalocean_record_id == record.digitalocean_record_id)) == 1 ->
        with :ok <- DigitalOcean.update_record(token, name, exact["id"], record) do
          {:ok, exact["id"], remote}
        end

      exact ->
        {:ok, exact["id"], remote}

      linked &&
          (linked["type"] != record.type || linked["name"] != Record.fqdn(record.name, name)) ->
        {:error, "Linked DigitalOcean record changed name/type; review before synchronizing"}

      linked &&
          Enum.count(records, &(&1.digitalocean_record_id == record.digitalocean_record_id)) != 1 ->
        {:error, "Multiple local records share this DigitalOcean ID"}

      linked && Enum.any?(records, &(&1.id != record.id and same?(&1, linked, name))) ->
        {:error, "Linked value is required by another local record"}

      linked ->
        with :ok <- DigitalOcean.update_record(token, name, linked["id"], record),
             {:ok, body} <- canonical(record, name) do
          {:ok, linked["id"],
           Enum.map(remote, fn r ->
             if r["id"] == linked["id"], do: Map.put(body, "id", linked["id"]), else: r
           end)}
        end

      true ->
        with {:ok, id} <- DigitalOcean.create_record(token, name, record),
             {:ok, body} <- canonical(record, name) do
          {:ok, id, [Map.put(body, "id", id) | remote]}
        end
    end
  end

  defp same?(record, remote, name) do
    # Permit exact adoption of apex NS without enabling authoritative NS mutations.
    record = %{record | name: Record.fqdn(record.name, name)}

    case Record.body(record) do
      {:ok, body} -> Record.same_data?(body, remote)
      _ -> false
    end
  end

  defp canonical(record, name) do
    with {:ok, body} <- DigitalOcean.body(record, name),
         do: {:ok, DigitalOcean.normalize(Map.put(body, "id", 0), name)}
  end

  defp normalize(records, name),
    do: records |> Enum.map(&DigitalOcean.normalize(&1, name)) |> Enum.reject(&is_nil/1)

  defp connection(zone) do
    with {:ok, token} <- token(zone),
         true <- is_binary(zone.digitalocean_zone_name) do
      {:ok, token, zone.digitalocean_zone_name}
    else
      false -> {:error, "Link this domain to DigitalOcean first"}
      error -> error
    end
  end

  defp token(zone) do
    case Settings.dns_setting_for_zone(zone) do
      %{provider: "digitalocean", digitalocean_api_token: token}
      when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        {:error, "Configure a DigitalOcean token at panel or domain level"}
    end
  end

  defp error(reason) when is_binary(reason), do: reason
  defp error(_), do: "Could not persist the DigitalOcean record; refresh before retrying"
end
