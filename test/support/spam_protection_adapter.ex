defmodule Hostctl.SpamProtection.TestAdapter do
  @moduledoc false
  def apply(bundle) do
    Agent.get_and_update(__MODULE__, fn state ->
      case state.result do
        :ok ->
          {:ok,
           %{
             state
             | actual: %{
                 enabled: bundle.enabled,
                 healthy?: bundle.enabled,
                 digest: bundle.digest,
                 message: "Checked"
               }
           }}

        error ->
          {error, state}
      end
    end)
  end

  def status, do: Agent.get(__MODULE__, & &1.actual)
end
