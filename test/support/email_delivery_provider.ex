defmodule Hostctl.EmailDelivery.TestProvider do
  def find_zone(_, _), do: {:ok, "zone"}
  def list_records(_, _), do: {:ok, Agent.get(__MODULE__, & &1.records)}
  def lookup(name, type), do: Agent.get(__MODULE__, &Map.get(&1.lookups, {name, type}, {:ok, []}))
  def create_record(_, _, attrs), do: write(nil, attrs)

  def update_record(_, _, id, attrs) do
    case write(id, attrs) do
      {:ok, _} -> :ok
      error -> error
    end
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
