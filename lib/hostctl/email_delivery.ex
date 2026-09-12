defmodule Hostctl.EmailDelivery do
  @moduledoc "Admin-only delivery setup with reviewed, conflict-checked DNS publication."
  import Ecto.Query
  alias Hostctl.{Repo, Hosting, Settings, SpamProtection}
  alias Hostctl.Accounts.Scope
  alias Hostctl.Hosting.{Domain, DnsZone, DnsRecord}
  alias Hostctl.EmailDelivery.{Setting, Plan, DNS, SPF}

  def mailgun_requirements(%{sending_dns_records: records}, domain) do
    dkim =
      records
      |> Enum.filter(fn r ->
        String.contains?(r["name"] || "", "._domainkey") && r["record_type"] in ["TXT", "CNAME"]
      end)
      |> Enum.map_join("\n", fn r ->
        name = DNS.normalize(r["name"])
        name = if Plan.in_zone?(name, domain), do: name, else: "#{name}.#{domain}"
        "#{name} #{r["record_type"]} #{DNS.txt(r["value"])}"
      end)

    # Mailgun's documented authorization; never import its replacement SPF/all policy.
    %{spf_include: "mailgun.org", dkim_records: dkim}
  end

  def list_domains(%Scope{user: %{role: "admin"}}),
    do: Repo.all(from d in Domain, order_by: d.name)

  def get_setting(%Scope{user: %{role: "admin"}}, domain_id) do
    domain = Repo.get!(Domain, domain_id)

    setting =
      Repo.get_by(Setting, domain_id: domain.id) ||
        %Setting{domain_id: domain.id, hostname: "mail.#{domain.name}"}

    %{setting | domain: domain}
  end

  def save(%Scope{user: %{role: "admin"}} = scope, domain_id, attrs) do
    get_setting(scope, domain_id) |> Setting.changeset(attrs) |> Repo.insert_or_update()
  end

  def route(%Scope{user: %{role: "admin"}}, setting) do
    domain_relay = Hosting.get_domain_smarthost_setting(setting.domain)
    server_relay = Settings.get_smarthost_setting()

    cond do
      domain_relay.enabled -> {:relay, domain_relay.host}
      server_relay.enabled -> {:relay, server_relay.host}
      true -> {:direct, nil}
    end
  end

  def preview(%Scope{user: %{role: "admin"}} = scope, domain_id) do
    setting = get_setting(scope, domain_id)
    {mode, relay} = route(scope, setting)

    with {:ok, source, records} <- snapshot(setting, mode) do
      rows = Plan.build(setting, mode, records) |> Enum.map(&check_spf/1)

      {:ok,
       %{
         domain_id: domain_id,
         setting: setting,
         route: {mode, relay},
         source: source,
         snapshot: fingerprint(records),
         rows: rows,
         created_at: System.monotonic_time(:second)
       }}
    end
  end

  def publish(%Scope{user: %{role: "admin"}} = scope, plan) do
    :global.trans({{__MODULE__, :dns}, self()}, fn ->
      with true <- System.monotonic_time(:second) - plan.created_at < 900,
           false <- Enum.any?(plan.rows, &(&1.action == :blocked)),
           {:ok, fresh} <- preview(scope, plan.domain_id),
           true <-
             fresh.snapshot == plan.snapshot && fresh.source == plan.source &&
               fresh.route == plan.route && fresh.rows == plan.rows,
           %{provider: :cloudflare, zone: zone} <- fresh.source do
        token = Settings.dns_setting_for_domain(fresh.setting.domain).cloudflare_api_token

        results =
          Enum.reduce_while(plan.rows, [], fn row, results ->
            if row.action == :keep do
              {:cont, results}
            else
              attrs =
                Map.take(row, [:type, :name, :value]) |> Map.merge(%{ttl: 300, proxied: false})

              result =
                case row.action do
                  :create ->
                    cloudflare().create_record(token, zone, attrs)

                  :update ->
                    case cloudflare().update_record(token, zone, row.before.id, attrs) do
                      :ok -> {:ok, row.before.id}
                      error -> error
                    end
                end

              case result do
                {:ok, id} ->
                  mirror(fresh.setting, attrs, id, row.before)
                  {:cont, results ++ [row.name]}

                {:error, _} ->
                  {:halt,
                   {:error,
                    "Publication stopped at #{row.name}. #{length(results)} changes succeeded; check Cloudflare and preview again before retrying."}}
              end
            end
          end)

        case results do
          {:error, _} = error ->
            error

          _ ->
            {:ok,
             "Cloudflare accepted #{length(results)} changes. Verify public DNS to check propagation."}
        end
      else
        _ ->
          {:error,
           "Preview expired, settings/DNS changed, or a conflict remains. Preview again before publishing. Other providers require manual publication."}
      end
    end)
  end

  def verify(%Scope{user: %{role: "admin"}} = scope, plan) do
    setting = get_setting(scope, plan.domain_id)

    checks =
      Enum.map(plan.rows, fn row ->
        result =
          if row.action == :blocked do
            {:error, row.reason}
          else
            with {:ok, values} <- dns().lookup(row.name, row.type) do
              relevant =
                if row.label in ["SPF", "DMARC"],
                  do:
                    Enum.filter(
                      values,
                      &String.starts_with?(
                        String.downcase(&1),
                        if(row.label == "SPF", do: "v=spf1", else: "v=dmarc1")
                      )
                    ),
                  else: values

              if length(relevant) == 1 && equal?(hd(relevant), row.value, row.type),
                do: :ok,
                else: {:error, "Not yet matching public DNS"}
            end
          end

        %{id: "record-#{row.id}", name: "#{row.label}: #{row.name}", result: result}
      end)

    {mode, _} = route(scope, setting)

    extra =
      if mode == :direct,
        do: ptr_checks(setting),
        else: [
          %{
            id: "relay",
            name: "Relay signing",
            result:
              {:error,
               "Confirm DKIM is enabled at your relay and send a test message; DNS alone cannot prove signing"}
          }
        ]

    checks ++ extra
  end

  def prepare_key(%Scope{user: %{role: "admin"}} = scope, domain_id) do
    setting = get_setting(scope, domain_id)

    with {:direct, _} <- route(scope, setting),
         %{healthy?: true, pending?: false} <- SpamProtection.status(scope),
         {:ok, key} <- system().prepare_key(setting.domain.name, setting.selector) do
      setting
      |> Ecto.Changeset.change(selector: key.selector, public_key: key.public_key)
      |> Repo.insert_or_update()
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         "Apply Spam Protection successfully on the Linux mail server before preparing a direct-sending key"}
    end
  end

  def enable_signing(%Scope{user: %{role: "admin"}} = scope, domain_id) do
    setting = get_setting(scope, domain_id)

    with {:direct, _} <- route(scope, setting),
         true <- is_binary(setting.public_key) && is_binary(setting.selector),
         {:ok, [value]} <-
           dns().lookup("#{setting.selector}._domainkey.#{setting.domain.name}", "TXT"),
         true <- value == "v=DKIM1; k=rsa; p=#{setting.public_key}",
         %{healthy?: true, pending?: false} <- SpamProtection.status(scope),
         {:ok, key} <- system().prepare_key(setting.domain.name, setting.selector),
         true <- key.public_key == setting.public_key,
         {:ok, updated} <- Repo.update(Ecto.Changeset.change(setting, signing_enabled: true)) do
      case SpamProtection.apply(scope) do
        :ok ->
          {:ok,
           "DKIM signing applied for authenticated SMTP mail. Send a test message to confirm authentication results."}

        {:error, reason} ->
          Repo.update!(Ecto.Changeset.change(updated, signing_enabled: setting.signing_enabled))
          {:error, reason}
      end
    else
      _ ->
        {:error,
         "Signing requires healthy, fully applied Spam Protection and the exact public DKIM key visible in DNS"}
    end
  end

  def signing_domains(%Scope{user: %{role: "admin"}}) do
    Repo.all(
      from s in Setting, where: s.signing_enabled == true, order_by: s.domain_id, preload: :domain
    )
  end

  defp snapshot(setting, mode) do
    case Settings.dns_setting_for_domain(setting.domain) do
      %{provider: "cloudflare", cloudflare_api_token: token}
      when is_binary(token) and token != "" ->
        with {:ok, zone} <- cloudflare().find_zone(token, setting.domain.name),
             {:ok, records} <- cloudflare().list_records(token, zone) do
          normalized =
            Enum.map(records, fn r ->
              %{
                id: r["id"],
                type: r["type"],
                name: DNS.normalize(r["name"]),
                value: if(r["type"] == "TXT", do: DNS.txt(r["content"]), else: r["content"]),
                proxied: r["proxied"] || false
              }
            end)

          {:ok, %{provider: :cloudflare, zone: zone}, normalized}
        else
          _ ->
            {:error,
             "Could not read the Cloudflare zone. Check the configured token and zone access; no records changed."}
        end

      _ ->
        public_snapshot(setting, mode)
    end
  end

  defp public_snapshot(setting, mode) do
    # Read the exact prospective owners, including CNAME conflicts, from public DNS.
    initial = Plan.build(setting, mode, [])

    names =
      Enum.uniq([
        setting.domain.name,
        "_dmarc.#{setting.domain.name}" | Enum.map(initial, & &1.name)
      ])

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      result =
        Enum.reduce_while(["CNAME", "TXT", "A", "AAAA"], {:ok, []}, fn type, {:ok, records} ->
          case if(Enum.any?(records, &(&1.type == "CNAME")),
                 do: {:ok, []},
                 else: dns().lookup(name, type)
               ) do
            {:ok, values} ->
              {:cont,
               {:ok,
                records ++
                  Enum.map(values, &%{id: nil, type: type, name: name, value: &1, proxied: false})}}

            error ->
              {:halt, error}
          end
        end)

      case result do
        {:ok, records} -> {:cont, {:ok, acc ++ records}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, %{provider: :manual}, records}
      error -> error
    end
  end

  defp mirror(setting, attrs, id, before) do
    # Cloudflare is authoritative here. A mirror failure must not trigger another API write.
    with %DnsZone{} = zone <- Repo.get_by(DnsZone, domain_id: setting.domain_id) do
      local =
        Repo.all(from r in DnsRecord, where: r.dns_zone_id == ^zone.id and r.type == ^attrs.type)

      candidates =
        Enum.filter(local, fn r ->
          DNS.normalize(r.name) == attrs.name && r.value in [attrs.value, before && before.value]
        end)

      record =
        Enum.find(local, &(&1.cloudflare_record_id == id)) ||
          case candidates do
            [record] -> record
            _ -> %DnsRecord{dns_zone_id: zone.id}
          end

      record
      |> DnsRecord.changeset(attrs)
      |> Ecto.Changeset.put_change(:cloudflare_record_id, id)
      |> Repo.insert_or_update()
    end
  end

  defp check_spf(%{label: "SPF", action: action} = row) when action in [:create, :update] do
    case SPF.validate(row.value, fn name, type -> dns().lookup(name, type) end) do
      :ok -> row
      {:error, reason} -> %{row | action: :blocked, reason: reason}
    end
  end

  defp check_spf(row), do: row

  defp fingerprint(records),
    do: records |> Enum.sort() |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1))

  defp equal?(a, b, "TXT"), do: a == b

  defp equal?(a, b, type) when type in ["A", "AAAA"],
    do: :inet.parse_address(to_charlist(a)) == :inet.parse_address(to_charlist(b))

  defp equal?(a, b, _), do: DNS.normalize(a) == DNS.normalize(b)

  defp ptr_checks(setting) do
    ips = Enum.reject([setting.ipv4, setting.ipv6], &is_nil/1)

    checks =
      Enum.map(ips, fn ip ->
        result =
          with true <- is_binary(setting.hostname),
               {:ok, ptrs} <- dns().lookup(DNS.reverse(ip), "PTR"),
               true <- Enum.any?(ptrs, &(DNS.normalize(&1) == DNS.normalize(setting.hostname))),
               {:ok, forwards} <-
                 dns().lookup(
                   setting.hostname,
                   if(String.contains?(ip, ":"), do: "AAAA", else: "A")
                 ),
               true <- Enum.any?(forwards, &equal?(&1, ip, "A")) do
            :ok
          else
            _ ->
              {:error,
               "Set PTR to #{setting.hostname || "your mail hostname"} with the IP hosting provider, and point that hostname back to this IP"}
          end

        %{id: "ptr-#{ip}", name: "Forward / reverse DNS: #{ip}", result: result}
      end)

    checks ++
      [
        %{
          id: "identity",
          name: "Outbound server identity",
          result:
            {:error,
             "Confirm Postfix HELO and actual outbound IPv4/IPv6 match these settings. DNS configuration does not change the server hostname or sending route."}
        }
      ]
  end

  defp dns, do: Application.get_env(:hostctl, :email_delivery_dns, DNS)

  defp cloudflare,
    do: Application.get_env(:hostctl, :email_delivery_cloudflare, Hostctl.DNS.Cloudflare)

  defp system,
    do: Application.get_env(:hostctl, :email_delivery_system, Hostctl.EmailDelivery.System)
end
