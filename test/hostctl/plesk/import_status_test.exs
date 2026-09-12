defmodule Hostctl.Plesk.ImportStatusTest do
  use ExUnit.Case, async: true
  alias Hostctl.Plesk.ImportStatus

  test "legacy or missing transfers cannot be reported as complete" do
    legacy = {:ok, %{categories: %{"web_files" => %{created: 1, failed: 0}}}}
    assert ImportStatus.summarize(legacy, [], true).state == :unknown
    current = {:ok, %{categories: %{"web_files" => %{job_ids: [42], failed: 0}}}}
    assert ImportStatus.summarize(current, [], true).state == :unknown
    unrelated = %{id: 43, status: "completed", failed_files: 0}
    assert ImportStatus.summarize(current, [unrelated], true).state == :unknown
  end

  test "paused and partially failed transfers need attention" do
    result = {:ok, %{categories: %{"web_files" => %{job_ids: [42], failed: 0}}}}

    assert ImportStatus.summarize(result, [%{id: 42, status: "paused", failed_files: 0}], true).state ==
             :failed

    assert ImportStatus.summarize(result, [%{id: 42, status: "completed", failed_files: 1}], true).state ==
             :failed
  end
end
