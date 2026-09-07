defmodule Hostctl.EmailDelivery.SPF do
  @moduledoc "Bounds recursive SPF lookups before publishing a new sender authorization."
  alias Hostctl.EmailDelivery.Plan

  def validate(value, lookup) do
    case count(value, lookup, [], 0) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp count(value, lookup, seen, used) do
    Enum.reduce_while(String.split(value) |> Enum.drop(1), {:ok, used}, fn term, {:ok, used} ->
      term = String.trim_leading(term, "+")

      result =
        cond do
          used > 10 ->
            {:error, "SPF exceeds the ten DNS-lookup limit"}

          String.starts_with?(term, "include:") ->
            name = String.replace_prefix(term, "include:", "")

            cond do
              name in seen ->
                {:error, "SPF include loop detected"}

              used >= 10 ->
                {:error, "SPF exceeds the ten DNS-lookup limit"}

              not Hostctl.EmailDelivery.Setting.hostname?(name) ->
                {:error, "SPF include needs manual review"}

              true ->
                with {:ok, values} <- lookup.(name, "TXT"),
                     [record] <-
                       Plan.policy(
                         Enum.map(values, &%{type: "TXT", name: name, value: &1}),
                         name,
                         "v=spf1"
                       ) do
                  count(record.value, lookup, [name | seen], used + 1)
                else
                  {:error, _} = error -> error
                  _ -> {:error, "SPF include #{name} must publish exactly one SPF policy"}
                end
            end

          Regex.match?(~r/\A[?~-]?(a|mx)(:|\/|$)/, term) && not String.contains?(term, "%") ->
            {:ok, used + 1}

          Regex.match?(~r/\A[?~-]?(all|ip4:[0-9.\/]+|ip6:[a-fA-F0-9:\/]+)\z/, term) ->
            {:ok, used}

          true ->
            {:error, "SPF uses mechanisms requiring manual lookup-budget review"}
        end

      case result do
        {:ok, n} when n <= 10 -> {:cont, result}
        {:ok, _} -> {:halt, {:error, "SPF exceeds the ten DNS-lookup limit"}}
        error -> {:halt, error}
      end
    end)
  end
end
