defmodule Hostctl.Portainer.System do
  @moduledoc false
  def call(operation, payload) do
    Hostctl.Privileged.call(operation, payload,
      socket: "/run/hostctl-portainer/control.sock",
      timeout: 240_000
    )
  end
end
