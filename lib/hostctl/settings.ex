defmodule Hostctl.Settings do
  @moduledoc """
  Context for server-level panel settings (admin only).
  """

  import Ecto.Query
  alias Hostctl.Repo
  alias Hostctl.Settings.ServerIpSetting
  alias Hostctl.Settings.DnsProviderSetting
  alias Hostctl.Settings.DnsTemplateRecord
  alias Hostctl.Settings.FeatureSetting

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

  # ---------------------------------------------------------------------------
  # DNS provider settings
  # ---------------------------------------------------------------------------

  @doc """
  Returns the current DNS provider setting, or a default struct if none exists.
  """
  def get_dns_provider_setting do
    Repo.one(from s in DnsProviderSetting, order_by: [asc: s.id], limit: 1) ||
      %DnsProviderSetting{}
  end

  @doc """
  Upserts the DNS provider setting. Only one row is maintained globally.
  """
  def save_dns_provider_setting(attrs) do
    case get_dns_provider_setting() do
      %DnsProviderSetting{id: nil} = new ->
        new
        |> DnsProviderSetting.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> DnsProviderSetting.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "Returns a changeset for the DNS provider setting."
  def change_dns_provider_setting(%DnsProviderSetting{} = setting, attrs \\ %{}) do
    DnsProviderSetting.changeset(setting, attrs)
  end

  @doc """
  Returns true if Cloudflare is configured as the active DNS provider.
  """
  def cloudflare_enabled? do
    case get_dns_provider_setting() do
      %DnsProviderSetting{provider: "cloudflare", cloudflare_api_token: token}
      when is_binary(token) and token != "" ->
        true

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # DNS template records
  # ---------------------------------------------------------------------------

  @doc "Returns all DNS template records ordered by type then name."
  def list_dns_template_records do
    Repo.all(from t in DnsTemplateRecord, order_by: [asc: t.type, asc: t.name])
  end

  @doc "Gets a single DNS template record by id, raises if not found."
  def get_dns_template_record!(id), do: Repo.get!(DnsTemplateRecord, id)

  @doc "Creates a DNS template record."
  def create_dns_template_record(attrs) do
    %DnsTemplateRecord{}
    |> DnsTemplateRecord.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a DNS template record."
  def update_dns_template_record(%DnsTemplateRecord{} = record, attrs) do
    record
    |> DnsTemplateRecord.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a DNS template record."
  def delete_dns_template_record(%DnsTemplateRecord{} = record) do
    Repo.delete(record)
  end

  @doc "Returns a changeset for a DNS template record."
  def change_dns_template_record(%DnsTemplateRecord{} = record, attrs \\ %{}) do
    DnsTemplateRecord.changeset(record, attrs)
  end

  @doc """
  Resolves all template records for a given domain name, substituting placeholders
  in `name` and `value` fields. Supported placeholders:

    - `{{domain}}`  — the domain name (e.g. `example.com`)
    - `{{ip}}`      — the server's primary IPv4 address (external IP if set)
    - `{{ipv6}}`    — the server's primary IPv6 address (external IP if set)
    - `{{hostname}}`— the server's hostname

  Returns a list of attribute maps ready to pass to `Hosting.create_dns_record/2`.
  """
  def resolve_dns_template(domain_name) do
    {ipv4, ipv6} = primary_server_ips()
    hostname = server_hostname()

    list_dns_template_records()
    |> Enum.map(fn record ->
      %{
        type: record.type,
        name: substitute(record.name, domain_name, ipv4, ipv6, hostname),
        value: substitute(record.value, domain_name, ipv4, ipv6, hostname),
        ttl: record.ttl,
        priority: record.priority
      }
    end)
  end

  @default_template_records [
    %{
      type: "NS",
      name: "{{domain}}",
      value: "ns1.{{domain}}",
      ttl: 86400,
      description: "Primary nameserver"
    },
    %{
      type: "NS",
      name: "{{domain}}",
      value: "ns2.{{domain}}",
      ttl: 86400,
      description: "Secondary nameserver"
    },
    %{
      type: "A",
      name: "{{domain}}",
      value: "{{ip}}",
      ttl: 14400,
      description: "Root domain A record"
    },
    %{
      type: "AAAA",
      name: "{{domain}}",
      value: "{{ipv6}}",
      ttl: 14400,
      description: "Root domain AAAA record"
    },
    %{
      type: "MX",
      name: "{{domain}}",
      value: "mail.{{domain}}",
      ttl: 14400,
      priority: 10,
      description: "Mail server"
    },
    %{
      type: "TXT",
      name: "{{domain}}",
      value: "v=spf1 +a +mx +a:{{hostname}} -all",
      ttl: 300,
      description: "SPF record"
    },
    %{
      type: "TXT",
      name: "_dmarc.{{domain}}",
      value: "v=DMARC1; p=quarantine; adkim=s; aspf=s",
      ttl: 300,
      description: "DMARC policy"
    },
    %{
      type: "TXT",
      name: "_domainconnect.{{domain}}",
      value: "domainconnect.plesk.com/host/{{hostname}}/port/8443",
      ttl: 60,
      description: "Domain connect"
    },
    %{
      type: "CNAME",
      name: "ftp.{{domain}}",
      value: "{{domain}}",
      ttl: 14400,
      description: "FTP subdomain"
    },
    %{
      type: "A",
      name: "ipv4.{{domain}}",
      value: "{{ip}}",
      ttl: 14400,
      description: "IPv4 subdomain"
    },
    %{
      type: "AAAA",
      name: "ipv6.{{domain}}",
      value: "{{ipv6}}",
      ttl: 14400,
      description: "IPv6 subdomain"
    },
    %{
      type: "A",
      name: "mail.{{domain}}",
      value: "{{ip}}",
      ttl: 14400,
      description: "Mail server A record"
    },
    %{
      type: "AAAA",
      name: "mail.{{domain}}",
      value: "{{ipv6}}",
      ttl: 14400,
      description: "Mail server AAAA record"
    },
    %{
      type: "A",
      name: "ns1.{{domain}}",
      value: "{{ip}}",
      ttl: 14400,
      description: "Primary NS A record"
    },
    %{
      type: "AAAA",
      name: "ns1.{{domain}}",
      value: "{{ipv6}}",
      ttl: 14400,
      description: "Primary NS AAAA record"
    },
    %{
      type: "A",
      name: "ns2.{{domain}}",
      value: "{{ip}}",
      ttl: 14400,
      description: "Secondary NS A record"
    },
    %{
      type: "AAAA",
      name: "ns2.{{domain}}",
      value: "{{ipv6}}",
      ttl: 14400,
      description: "Secondary NS AAAA record"
    },
    %{
      type: "A",
      name: "webmail.{{domain}}",
      value: "{{ip}}",
      ttl: 14400,
      description: "Webmail A record"
    },
    %{
      type: "AAAA",
      name: "webmail.{{domain}}",
      value: "{{ipv6}}",
      ttl: 14400,
      description: "Webmail AAAA record"
    },
    %{
      type: "CNAME",
      name: "www.{{domain}}",
      value: "{{domain}}",
      ttl: 14400,
      description: "WWW subdomain"
    }
  ]

  @doc """
  Deletes all existing template records and inserts the Plesk-style default set.
  """
  def load_default_dns_template_records do
    Repo.delete_all(DnsTemplateRecord)

    Enum.each(@default_template_records, fn attrs ->
      %DnsTemplateRecord{}
      |> DnsTemplateRecord.changeset(attrs)
      |> Repo.insert!()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Feature settings
  # ---------------------------------------------------------------------------

  @doc "Returns all feature settings."
  def list_feature_settings do
    Repo.all(from f in FeatureSetting, order_by: [asc: f.key])
  end

  @doc """
  Returns the feature setting for the given key, or creates a disabled one if
  it doesn't exist yet.
  """
  def get_feature_setting(key) when is_binary(key) do
    case Repo.get_by(FeatureSetting, key: key) do
      nil ->
        %FeatureSetting{key: key, enabled: false, status: "not_installed"}

      setting ->
        setting
    end
  end

  @doc "Updates a feature setting (upsert)."
  def save_feature_setting(key, attrs) when is_binary(key) do
    case Repo.get_by(FeatureSetting, key: key) do
      nil ->
        %FeatureSetting{key: key}
        |> FeatureSetting.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> FeatureSetting.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "Returns true if the given feature key is enabled."
  def feature_enabled?(key) when is_binary(key) do
    case Repo.get_by(FeatureSetting, key: key) do
      %FeatureSetting{enabled: true, status: "installed"} -> true
      _ -> false
    end
  end

  defp primary_server_ips do
    settings = list_ip_settings()

    ipv4 =
      Enum.find_value(settings, "", fn s ->
        ip = s.external_ip || s.ip_address
        if String.contains?(ip, ".") and not String.contains?(ip, ":"), do: ip
      end)

    ipv6 =
      Enum.find_value(settings, "", fn s ->
        ip = s.external_ip || s.ip_address
        if String.contains?(ip, ":"), do: ip
      end)

    {ipv4, ipv6}
  end

  defp server_hostname do
    case System.cmd("hostname", []) do
      {hostname, 0} -> String.trim(hostname)
      _ -> ""
    end
  end

  defp substitute(str, domain, ip, ipv6, hostname) do
    str
    |> String.replace("{{domain}}", domain)
    |> String.replace("{{ip}}", ip)
    |> String.replace("{{ipv6}}", ipv6)
    |> String.replace("{{hostname}}", hostname)
  end
end
