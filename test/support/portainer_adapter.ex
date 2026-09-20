defmodule Hostctl.Portainer.TestAdapter do
  def call(operation, payload) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | calls: [{operation, payload} | state.calls]}

      case operation do
        "portainer-status" ->
          {{:ok, state.agent}, state}

        "portainer-remove" ->
          agent = %{"installed" => false, "running" => false}
          {{:ok, agent}, %{state | agent: agent}}

        "portainer-install" ->
          agent = %{
            "installed" => true,
            "running" => true,
            "version" => payload.version,
            "bind_address" => payload.bind_address,
            "port" => 9001
          }

          {{:ok, agent}, %{state | agent: agent}}
      end
    end)
  end
end
