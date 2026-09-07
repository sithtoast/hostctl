defmodule Hostctl.EmailDelivery.DNS do
  @moduledoc "Public DNS checks. Lookup failures are never treated as missing records."
  @types %{"A" => 1, "AAAA" => 28, "TXT" => 16, "CNAME" => 5, "MX" => 15, "PTR" => 12}

  def lookup(name, type) do
    with {:ok, %{status: 200, body: raw}} <-
           Req.get("https://cloudflare-dns.com/dns-query",
             params: [name: name, type: type],
             headers: [{"accept", "application/dns-json"}],
             receive_timeout: 8_000,
             decode_body: false,
             retry: false
           ),
         {:ok, %{"Status" => status} = body} <- Jason.decode(raw),
         true <- status in [0, 3] do
      answers = Map.get(body, "Answer", [])

      if type == "TXT" and Enum.any?(answers, &(&1["type"] == 5)) do
        {:error, "#{name} is a CNAME; manage authentication at its DNS provider"}
      else
        {:ok,
         answers
         |> Enum.filter(&(&1["type"] == @types[type]))
         |> Enum.map(fn r -> if type == "TXT", do: txt(r["data"]), else: r["data"] end)}
      end
    else
      _ ->
        {:error, "Public #{type} lookup failed for #{name}; retry before changing DNS"}
    end
  end

  def txt(value) do
    if String.starts_with?(value, "\"") do
      Regex.scan(~r/"((?:[^"\\]|\\.)*)"/, value, capture: :all_but_first)
      |> List.flatten()
      |> Enum.join()
      |> String.replace("\\\"", "\"")
      |> String.replace("\\\\", "\\")
    else
      value
    end
  end

  def reverse(ip) do
    {:ok, address} = :inet.parse_address(String.to_charlist(ip))

    if tuple_size(address) == 4 do
      address |> Tuple.to_list() |> Enum.reverse() |> Enum.join(".") |> Kernel.<>(".in-addr.arpa")
    else
      address
      |> Tuple.to_list()
      |> Enum.map_join(
        &(&1
          |> Integer.to_string(16)
          |> String.downcase()
          |> String.pad_leading(4, "0"))
      )
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.join(".")
      |> Kernel.<>(".ip6.arpa")
    end
  end

  def normalize(value), do: value |> String.trim_trailing(".") |> String.downcase()
end
