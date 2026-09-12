defmodule Hostctl.Resources.TestProcessReader do
  def snapshot, do: Agent.get(__MODULE__, & &1)
end
