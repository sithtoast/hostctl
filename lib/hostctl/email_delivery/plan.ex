defmodule Hostctl.EmailDelivery.Plan do
  @moduledoc "Conservative DNS changes: preserve policies and refuse ambiguous record sets."
  alias Hostctl.EmailDelivery.{DNS, Setting}

  def build(setting, route, records) do
    domain = String.downcase(setting.domain.name)

    terms =
      if route == :direct do
        Enum.reject([ip_term("ip4", setting.ipv4), ip_term("ip6", setting.ipv6)], &is_nil/1)
      else
        if setting.spf_include, do: ["include:#{setting.spf_include}"], else: []
      end

    spf = policy(records, domain, "v=spf1")
    dmarc = policy(records, "_dmarc.#{domain}", "v=DMARC1")

    spf_change =
      case merge_spf(spf, terms) do
        {:ok, value} -> change(records, "TXT", domain, value, "SPF", spf)
        {:error, reason} -> blocked("SPF", domain, reason)
      end

    dmarc_change =
      case dmarc do
        [] ->
          change(records, "TXT", "_dmarc.#{domain}", "v=DMARC1; p=none", "DMARC", [])

        [record] ->
          change(records, "TXT", record.name, record.value, "DMARC", [record])

        _ ->
          blocked(
            "DMARC",
            "_dmarc.#{domain}",
            "Multiple DMARC policies exist; resolve them first"
          )
      end

    dkim =
      if route == :direct do
        if setting.selector && setting.public_key do
          [
            %{
              type: "TXT",
              name: "#{setting.selector}._domainkey.#{domain}",
              value: "v=DKIM1; k=rsa; p=#{setting.public_key}"
            }
          ]
        else
          []
        end
      else
        {:ok, parsed} = parse_dkim(setting.dkim_records, domain)
        parsed
      end

    dkim_changes =
      if dkim == [] do
        [
          blocked(
            "DKIM",
            domain,
            if(route == :direct,
              do: "Prepare a signing key on the mail server",
              else: "Enter the relay provider’s DKIM records"
            )
          )
        ]
      else
        Enum.map(dkim, &change(records, &1.type, &1.name, &1.value, "DKIM"))
      end

    host_changes =
      if route == :direct && setting.hostname && in_zone?(setting.hostname, domain) do
        [{"A", setting.ipv4}, {"AAAA", setting.ipv6}]
        |> Enum.reject(fn {_, ip} -> is_nil(ip) end)
        |> Enum.map(fn {type, ip} ->
          change(records, type, setting.hostname, ip, "Mail hostname")
        end)
      else
        []
      end

    Enum.with_index([spf_change, dmarc_change] ++ dkim_changes ++ host_changes, fn r, i ->
      Map.put(r, :id, i)
    end)
  end

  def parse_dkim(nil, _domain), do: {:ok, []}

  def parse_dkim(text, domain) do
    lines = String.split(text, "\n", trim: true)

    parsed =
      Enum.map(lines, fn line ->
        case String.split(String.trim(line), ~r/\s+/, parts: 3) do
          [name, type, value] ->
            name = DNS.normalize(name)
            type = String.upcase(type)

            valid_name =
              Regex.match?(
                ~r/\A[a-z0-9-]{1,63}\._domainkey\.#{Regex.escape(String.downcase(domain))}\z/,
                name
              )

            valid_value =
              case type do
                "CNAME" ->
                  Setting.hostname?(String.trim_trailing(value, "."))

                "TXT" ->
                  String.starts_with?(value, "v=DKIM1;") and
                    Regex.match?(~r/(?:^|;)\s*p=[A-Za-z0-9+\/]{40,}={0,2}(?:;|\s*$)/, value)

                _ ->
                  false
              end

            if valid_name && valid_value,
              do: %{type: type, name: name, value: value},
              else: :invalid

          _ ->
            :invalid
        end
      end)

    if length(lines) <= 6 && :invalid not in parsed &&
         length(Enum.uniq_by(parsed, & &1.name)) == length(parsed) do
      {:ok, parsed}
    else
      {:error,
       "use up to six unique lines: selector._domainkey.your-domain TXT v=DKIM1; k=rsa; p=… or selector._domainkey.your-domain CNAME provider-hostname"}
    end
  end

  def merge_spf(_, []),
    do: {:error, "Enter the actual outbound IP addresses or the relay’s SPF include hostname"}

  def merge_spf([], terms), do: {:ok, Enum.join(["v=spf1" | terms] ++ ["~all"], " ")}

  def merge_spf([record], terms) do
    tokens = String.split(record.value)
    missing = Enum.reject(terms, &(&1 in tokens or "+#{&1}" in tokens))

    cond do
      missing == [] ->
        {:ok, record.value}

      hd(tokens) != "v=spf1" ->
        {:error, "Review the existing SPF syntax before changing it"}

      Enum.any?(
        tl(tokens),
        &(not Regex.match?(
            ~r/\A(?:[+?~-]?(?:a|mx)(?::[a-zA-Z0-9.-]+)?(?:\/\d+)?|[+?~-]?ip[46]:[a-fA-F0-9.:\/]+|[+?~-]?include:[a-zA-Z0-9.-]+|[+?~-]?all)\z/,
            &1
          ))
      ) ->
        {:error, "SPF uses advanced mechanisms or modifiers; merge the new sender manually"}

      length(Enum.filter(tokens, &Regex.match?(~r/\A[+?~-]?all\z/, &1))) != 1 or
          not Regex.match?(~r/\A[+?~-]?all\z/, List.last(tokens)) ->
        {:error, "SPF must have one final all mechanism before automatic merging"}

      true ->
        {:ok, Enum.join(Enum.drop(tokens, -1) ++ missing ++ [List.last(tokens)], " ")}
    end
  end

  def merge_spf(_, _),
    do: {:error, "Multiple SPF policies exist; resolve them before adding senders"}

  def policy(records, name, prefix),
    do:
      Enum.filter(
        records,
        &(&1.type == "TXT" && &1.name == name &&
            String.starts_with?(String.downcase(&1.value), String.downcase(prefix)))
      )

  def in_zone?(name, zone), do: name == zone or String.ends_with?(name, ".#{zone}")
  defp ip_term(_, nil), do: nil
  defp ip_term(type, ip), do: "#{type}:#{ip}"

  defp blocked(label, name, reason),
    do: %{
      label: label,
      name: name,
      type: "TXT",
      value: "",
      before: nil,
      action: :blocked,
      reason: reason
    }

  defp change(records, type, name, value, label, matching \\ nil) do
    name = DNS.normalize(name)
    matching = matching || Enum.filter(records, &(&1.name == name && &1.type == type))
    owner = Enum.filter(records, &(&1.name == name))

    {action, before, reason} =
      cond do
        Enum.any?(owner, &(&1.type == "CNAME" and type != "CNAME")) or
            (type == "CNAME" and Enum.any?(owner, &(&1.type != "CNAME"))) ->
          {:blocked, nil, "CNAME conflicts with another record at this name"}

        length(matching) > 1 ->
          {:blocked, nil, "Multiple records exist; review them manually"}

        matching == [] ->
          {:create, nil, "Create record"}

        hd(matching).value == value && not Map.get(hd(matching), :proxied, false) ->
          {:keep, hd(matching), "Preserve existing record"}

        label == "SPF" ->
          {:update, hd(matching), "Add sender; preserve existing authorizations and final policy"}

        hd(matching).value == value && Map.get(hd(matching), :proxied, false) ->
          {:update, hd(matching), "Turn off Cloudflare proxy for email"}

        true ->
          {:blocked, hd(matching),
           "Different record already exists; preserve it and review manually"}
      end

    %{
      label: label,
      name: name,
      type: type,
      value: value,
      before: before,
      action: action,
      reason: reason
    }
  end
end
