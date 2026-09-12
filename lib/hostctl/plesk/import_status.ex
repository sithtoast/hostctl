defmodule Hostctl.Plesk.ImportStatus do
  @moduledoc "Combines configuration results with the exact transfers scheduled by an import."

  def job_ids({_status, result}) do
    result
    |> Map.get(:categories, %{})
    |> Map.values()
    |> Enum.flat_map(&Map.get(&1, :job_ids, []))
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
  end

  def job_ids(_), do: []

  def summarize(nil, _jobs, _s3?), do: %{state: :idle, label: "Not started"}

  def summarize({status, result} = outcome, jobs, s3?) do
    ids = job_ids(outcome)
    transfers = Enum.filter(jobs, &(&1.id in ids))
    categories = Map.get(result, :categories, %{})
    recorded? = Enum.any?(Map.values(categories), &Map.has_key?(&1, :job_ids))

    cond do
      status == :error or Enum.any?(Map.values(categories), &(Map.get(&1, :failed, 0) > 0)) ->
        %{state: :failed, label: "Import needs attention"}

      Enum.any?(transfers, &(&1.status in ["failed", "paused"] or &1.failed_files > 0)) ->
        %{state: :failed, label: "Transfers need attention"}

      length(transfers) != length(ids) or (s3? and not recorded?) ->
        %{state: :unknown, label: "Configuration finished; transfer status unavailable"}

      Enum.any?(transfers, &(&1.status != "completed")) ->
        %{state: :running, label: "Transferring files"}

      true ->
        %{state: :completed, label: "Import complete"}
    end
  end
end
