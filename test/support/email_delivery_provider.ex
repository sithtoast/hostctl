defmodule Hostctl.EmailDelivery.TestProvider do
  def find_zone(token, _) do
    record_token(token)
    {:ok, "zone"}
  end

  def list_records(token, _) do
    record_token(token)
    {:ok, Agent.get(__MODULE__, & &1.records)}
  end

  def lookup(name, type), do: Agent.get(__MODULE__, &Map.get(&1.lookups, {name, type}, {:ok, []}))

  def create_record(token, _, attrs) do
    record_token(token)
    write(nil, attrs)
  end

  def update_record(token, _, id, attrs) do
    record_token(token)

    case write(id, attrs) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp record_token(token) do
    Agent.update(
      __MODULE__,
      &Map.update(&1, :tokens, [token], fn tokens -> tokens ++ [token] end)
    )
  end

  defp write(id, attrs) do
    Agent.get_and_update(__MODULE__, fn state ->
      if state.fail_after && length(state.writes) >= state.fail_after do
        {{:error, "provider unavailable"}, state}
      else
        id = id || "record-#{length(state.writes)}"

        record = %{
          "id" => id,
          "type" => attrs.type,
          "name" => attrs.name,
          "content" => attrs.value,
          "proxied" => Map.get(attrs, :proxied, false)
        }

        {{:ok, id},
         %{
           state
           | records: Enum.reject(state.records, &(&1["id"] == id)) ++ [record],
             writes: state.writes ++ [attrs]
         }}
      end
    end)
  end
end
