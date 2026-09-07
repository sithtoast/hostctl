defmodule HostctlWeb.NavigationHook do
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if socket.assigns.current_scope.user.role == "admin" do
      if connected?(socket), do: Phoenix.PubSub.subscribe(Hostctl.PubSub, "update_status")

      {:cont,
       socket
       |> assign(:update_status, Hostctl.UpdateMonitor.snapshot())
       |> attach_hook(:update_status, :handle_info, fn
         {:update_status, status}, socket -> {:halt, assign(socket, :update_status, status)}
         _, socket -> {:cont, socket}
       end)}
    else
      {:cont, assign(socket, :update_status, nil)}
    end
  end
end
