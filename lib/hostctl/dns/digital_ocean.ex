defmodule Hostctl.DNS.DigitalOcean do
  @moduledoc "DigitalOcean v2 DNS client. Linking only discovers existing domains."
  alias Hostctl.DNS.Record

  def verify_token(token) do
    with {:ok, %{"domains" => domains}} when is_list(domains) <-
           request(token, :get, "/domains", params: [per_page: 1]) do
      {:ok, :readable}
    else
      {:error, _} = error -> error
      _ -> {:error, "Unexpected DigitalOcean response"}
    end
  end

  def find_zone(token, name) do
    with {:ok, %{"domain" => %{"name" => found}}} <- request(token, :get, path(name)),
         true <- Record.hostname(found) == Record.hostname(name) do
      {:ok, found}
    else
      {:error, _} = error -> error
      _ -> {:error, "Unexpected DigitalOcean domain response"}
    end
  end

  def list_records(token, zone), do: pages(token, zone, 1, [])

  defp pages(token, zone, page, acc) when page <= 1000 do
    with {:ok, %{"domain_records" => records} = body} when is_list(records) <-
           request(token, :get, path(zone) <> "/records", params: [per_page: 200, page: page]),
         true <- Enum.all?(records, &valid_remote?/1) do
      # Never follow response URLs with credentials. Fetch the next page on our fixed origin.
      if get_in(body, ["links", "pages", "next"]) do
        pages(token, zone, page + 1, [records | acc])
      else
        {:ok, acc |> Enum.reverse() |> List.flatten() |> Kernel.++(records)}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Unexpected DigitalOcean record response"}
    end
  end

  defp pages(_, _, _, _), do: {:error, "DigitalOcean pagination limit exceeded"}

  defp valid_remote?(%{"id" => id, "type" => type, "name" => name, "data" => data}),
    do: is_integer(id) and is_binary(type) and is_binary(name) and is_binary(data)

  defp valid_remote?(_), do: false

  def create_record(token, zone, record) do
    with {:ok, body} <- body(record, zone),
         {:ok, %{"domain_record" => %{"id" => id}}} when is_integer(id) <-
           request(token, :post, path(zone) <> "/records", json: body) do
      {:ok, to_string(id)}
    else
      {:error, _} = error -> error
      _ -> {:error, "Unexpected DigitalOcean create response; refresh before retrying"}
    end
  end

  def update_record(token, zone, id, record) do
    with {:ok, body} <- body(record, zone),
         {:ok, _} <- request(token, :patch, path(zone) <> "/records/" <> segment(id), json: body) do
      :ok
    end
  end

  def delete_record(token, zone, id) do
    with {:ok, _} <- request(token, :delete, path(zone) <> "/records/" <> segment(id)), do: :ok
  end

  def body(record, zone) do
    fqdn = Record.fqdn(record.name, zone)
    zone = Record.hostname(zone)
    ttl = Map.get(record, :ttl) || 3600

    cond do
      record.type not in ~w(A AAAA CNAME MX TXT NS SRV CAA) ->
        {:error, "Unsupported DigitalOcean record type"}

      fqdn != zone and not String.ends_with?(fqdn, "." <> zone) ->
        {:error, "Record name must belong to this domain"}

      record.type == "NS" and fqdn == zone ->
        {:error, "Manage authoritative nameservers outside Hostctl; apex NS writes are disabled"}

      not is_integer(ttl) or ttl < 30 ->
        {:error, "DigitalOcean requires a TTL of at least 30 seconds"}

      true ->
        name = if fqdn == zone, do: "@", else: String.trim_trailing(fqdn, "." <> zone)
        base = %{"type" => record.type, "name" => name, "ttl" => ttl}
        with {:ok, fields} <- fields(record), do: {:ok, Map.merge(base, fields)}
    end
  end

  defp fields(%{type: "SRV"} = record) do
    with {:ok, %{"data" => data}} <- Record.body(record) do
      {:ok, data |> Map.put("data", data["target"]) |> Map.delete("target")}
    end
  end

  defp fields(%{type: "CAA", value: value}) do
    case Regex.run(~r/^(\d+)\s+(issue|issuewild|iodef)\s+(.+)$/, value) do
      [_, flags, tag, data] ->
        flags = String.to_integer(flags)
        data = String.trim(data, "\"")

        if flags <= 255 and not String.contains?(data, ";"),
          do: {:ok, %{"flags" => flags, "tag" => tag, "data" => data}},
          else: {:error, "Unsupported DigitalOcean CAA flags or value"}

      _ ->
        {:error, "CAA value must be 'flags tag value'"}
    end
  end

  defp fields(%{type: "MX"} = record) do
    if is_integer(record.priority) and record.priority in 0..65535,
      do: {:ok, %{"data" => Record.hostname(record.value), "priority" => record.priority}},
      else: {:error, "MX priority must be between 0 and 65535"}
  end

  defp fields(record) do
    value = if record.type in ~w(NS CNAME), do: Record.hostname(record.value), else: record.value
    {:ok, %{"data" => value}}
  end

  # Convert to the shared reconciliation representation, including structured SRV.
  def normalize(%{"id" => id, "type" => type, "name" => name, "data" => data} = r, zone)
      when is_integer(id) and is_binary(type) and is_binary(name) and is_binary(data) do
    content =
      case type do
        "SRV" -> "#{r["weight"]} #{r["port"]} #{data}"
        "CAA" -> "#{r["flags"]} #{r["tag"]} #{data}"
        _ -> data
      end

    result = %{
      "id" => to_string(id),
      "type" => type,
      "name" => Record.fqdn(name, zone),
      "content" => content,
      "ttl" => r["ttl"] || 3600,
      "priority" => r["priority"]
    }

    if type == "SRV",
      do:
        Map.put(result, "data", %{
          "weight" => r["weight"],
          "port" => r["port"],
          "priority" => r["priority"],
          "target" => data
        }),
      else: result
  end

  def normalize(_, _), do: nil

  defp path(zone), do: "/domains/" <> segment(zone)
  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp request(token, method, path, opts \\ []) do
    options = Application.get_env(:hostctl, :digitalocean_request_options, [])

    result =
      options
      |> Keyword.merge(opts)
      |> Keyword.merge(
        method: method,
        url: "https://api.digitalocean.com/v2" <> path,
        auth: {:bearer, token},
        retry: false,
        redirect: false,
        receive_timeout: 15_000
      )
      |> Req.request()

    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 401}} ->
        {:error, "DigitalOcean rejected the token (401)"}

      {:ok, %Req.Response{status: 403}} ->
        {:error, "DigitalOcean denied access; check domain token scopes (403)"}

      {:ok, %Req.Response{status: 404}} ->
        {:error, "Domain or record not found in DigitalOcean (404)"}

      {:ok, %Req.Response{status: 429}} ->
        {:error, "DigitalOcean rate limit reached; retry later (429)"}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         "DigitalOcean request failed (HTTP #{status}); check record fields and token permissions"}

      {:error, _} ->
        {:error, "DigitalOcean connection failed; refresh before retrying a write"}
    end
  end
end
