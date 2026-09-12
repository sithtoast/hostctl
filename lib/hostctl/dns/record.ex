defmodule Hostctl.DNS.Record do
  @moduledoc false

  # Hostctl/Plesk store SRV priority separately from "weight port target".
  def body(%{type: "SRV"} = record) do
    with [weight, port, target] <- String.split(record.value),
         {:ok, priority} <- uint16(Map.get(record, :priority)),
         {:ok, weight} <- uint16(weight),
         {:ok, port} <- uint16(port) do
      {:ok,
       Map.put(base(record), "data", %{
         "priority" => priority,
         "weight" => weight,
         "port" => port,
         "target" => hostname(target)
       })}
    else
      _ -> {:error, "Invalid SRV record: use priority and value 'weight port target' (0..65535)"}
    end
  end

  def body(record) do
    body = Map.put(base(record), "content", record.value)

    body =
      if record.type == "MX",
        do: Map.put(body, "priority", Map.get(record, :priority)),
        else: body

    {:ok, body}
  end

  defp base(record) do
    body = %{"type" => record.type, "name" => record.name, "ttl" => Map.get(record, :ttl) || 3600}

    if record.type in ~w(A AAAA CNAME) and Map.has_key?(record, :proxied),
      do: Map.put(body, "proxied", record.proxied),
      else: body
  end

  defp uint16(value) when is_integer(value) and value in 0..65535, do: {:ok, value}

  defp uint16(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> uint16(number)
      _ -> :error
    end
  end

  defp uint16(_), do: :error

  def hostname("."), do: "."
  def hostname(name), do: name |> String.trim_trailing(".") |> String.downcase()

  def fqdn("@", domain), do: hostname(domain)

  def fqdn(name, domain) do
    absolute? = String.ends_with?(name, ".")
    name = hostname(name)
    domain = hostname(domain)

    if absolute? or name == domain or String.ends_with?(name, "." <> domain),
      do: name,
      else: name <> "." <> domain
  end

  # Structured SRV data is authoritative; older responses also expose content.
  def local_value(%{"type" => "SRV", "data" => data}) when is_map(data) do
    {"#{data["weight"]} #{data["port"]} #{data["target"]}", data["priority"]}
  end

  def local_value(record), do: {record["content"], record["priority"]}

  def same_data?(body, remote) do
    body["type"] == remote["type"] and
      hostname(body["name"]) == hostname(remote["name"] || "") and
      data_key(body) == data_key(remote)
  end

  defp data_key(%{"type" => "SRV"} = record) do
    {value, priority} = local_value(record)

    case body(%{
           type: "SRV",
           name: record["name"],
           value: value || "",
           priority: priority,
           ttl: 1
         }) do
      {:ok, body} -> body["data"]
      _ -> :invalid
    end
  end

  defp data_key(%{"type" => type, "content" => content} = record) when type in ~w(NS CNAME MX) do
    {hostname(content), if(type == "MX", do: record["priority"])}
  end

  defp data_key(%{"type" => "AAAA", "content" => content}) do
    case :inet.parse_ipv6_address(String.to_charlist(content)) do
      {:ok, address} -> address
      _ -> content
    end
  end

  defp data_key(%{"type" => "CAA", "content" => content}) do
    case Regex.run(~r/^(\d+)\s+(\S+)\s+(.+)$/, content) do
      [_, flags, tag, value] -> {String.to_integer(flags), tag, String.trim(value, "\"")}
      _ -> content
    end
  end

  # TXT values are case-sensitive; never normalize arbitrary content.
  defp data_key(record), do: record["content"]
end
