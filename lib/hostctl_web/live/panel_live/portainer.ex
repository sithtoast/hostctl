defmodule HostctlWeb.PanelLive.Portainer do
  use HostctlWeb, :live_view
  alias Hostctl.Portainer

  @impl true
  def mount(_, _, socket) do
    socket =
      socket
      |> assign(
        page_title: "Portainer Agent",
        active_tab: :panel_features,
        busy: false,
        agent: nil,
        error: nil
      )
      |> assign(
        :form,
        to_form(Portainer.changeset(%{version: "", bind_address: "127.0.0.1", agent_secret: ""}),
          as: :agent
        )
      )

    {:ok, if(connected?(socket), do: refresh(socket), else: socket)}
  end

  @impl true
  def handle_event("install", %{"agent" => params}, socket) do
    changeset = Portainer.changeset(params)

    if socket.assigns.busy do
      {:noreply, socket}
    else
      if changeset.valid? do
        scope = socket.assigns.current_scope

        {:noreply,
         socket
         |> assign(busy: true, error: nil)
         |> assign(
           :form,
           to_form(Portainer.changeset(Map.put(params, "agent_secret", "")), as: :agent)
         )
         |> start_async(:operation, fn -> Portainer.install(scope, params) end)}
      else
        # Never render a submitted secret back into the page.
        safe =
          changeset |> Ecto.Changeset.put_change(:agent_secret, "") |> Map.put(:action, :insert)

        {:noreply, assign(socket, :form, to_form(safe, as: :agent))}
      end
    end
  end

  def handle_event("remove", _, socket) do
    if socket.assigns.busy do
      {:noreply, socket}
    else
      scope = socket.assigns.current_scope

      {:noreply,
       socket
       |> assign(busy: true, error: nil)
       |> start_async(:operation, fn -> Portainer.remove(scope) end)}
    end
  end

  def handle_event("refresh", _, socket),
    do: {:noreply, if(socket.assigns.busy, do: socket, else: refresh(socket))}

  @impl true
  def handle_async(:operation, {:ok, {:ok, agent}}, socket) do
    {:noreply, assign(socket, busy: false, agent: agent, error: nil)}
  end

  def handle_async(:operation, _, socket) do
    {:noreply,
     assign(socket,
       busy: false,
       error:
         "The agent operation could not be verified. Refresh status before retrying; check the server's hostctl-portainer service log if it persists."
     )}
  end

  def handle_async(:status, {:ok, {:ok, agent}}, socket),
    do: {:noreply, assign(socket, busy: false, agent: agent, error: nil)}

  def handle_async(:status, _, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         error:
           "Agent status is unavailable. Docker and the Hostctl Portainer service must be running on this server."
       )}

  defp refresh(socket) do
    scope = socket.assigns.current_scope
    socket |> assign(busy: true) |> start_async(:status, fn -> Portainer.status(scope) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab={@active_tab}
      update_status={assigns[:update_status]}
    >
      <div class="mx-auto max-w-3xl space-y-6">
        <div>
          <.link navigate={~p"/panel/features"} class="text-sm text-indigo-600 hover:text-indigo-800">
            Features
          </.link>
          <h1 class="mt-3 text-2xl font-semibold text-gray-900 dark:text-white">Portainer Agent</h1>
          <p class="mt-2 text-sm text-gray-500">
            Connect this Docker host to your existing Portainer server.
          </p>
        </div>
        <div class="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950 dark:border-amber-900 dark:bg-amber-950/30 dark:text-amber-100">
          The agent can manage this server through Docker. Bind to a private or VPN address where possible,
          and allow port 9001 only from your Portainer server. The installer does not change your firewall.
        </div>
        <div
          id="portainer-status"
          class="rounded-xl border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-900"
          aria-live="polite"
        >
          <div class="flex items-center justify-between gap-4">
            <div>
              <h2 class="font-semibold text-gray-900 dark:text-white">Agent status</h2>
              <p
                :if={@agent && @agent["running"]}
                id="portainer-running"
                class="mt-2 text-sm text-emerald-700 dark:text-emerald-400"
              >
                Running · {@agent["version"]} · {@agent["bind_address"]}:9001
              </p>
              <p
                :if={@agent && !@agent["installed"]}
                id="portainer-not-installed"
                class="mt-2 text-sm text-gray-500"
              >
                Not installed by Hostctl
              </p>
              <p
                :if={@agent && @agent["installed"] && !@agent["running"]}
                id="portainer-stopped"
                class="mt-2 text-sm text-amber-600"
              >
                Installed, but stopped. Reinstall with the same settings to start it, or remove it.
              </p>
              <p :if={@busy} id="portainer-busy" class="mt-2 text-sm text-gray-500">
                Working… image downloads can take a few minutes.
              </p>
            </div>
            <button
              id="refresh-portainer"
              phx-click="refresh"
              disabled={@busy}
              class="rounded-lg border border-gray-300 px-3 py-2 text-sm transition hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:hover:bg-gray-800"
            >
              Refresh
            </button>
          </div>
          <p :if={@error} id="portainer-error" class="mt-3 text-sm text-red-600 dark:text-red-400">
            {@error}
          </p>
        </div>
        <.form
          for={@form}
          id="portainer-install-form"
          phx-submit="install"
          class="space-y-5 rounded-xl border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-900"
        >
          <h2 class="font-semibold text-gray-900 dark:text-white">Install Standard Agent</h2>
          <.input
            field={@form[:version]}
            label="Portainer server version"
            placeholder="2.39.0"
            required
          />
          <p class="text-xs text-gray-500">
            Use the exact version shown in your Portainer server. The agent version must match.
          </p>
          <.input field={@form[:bind_address]} label="Listen address on this server" required />
          <p class="text-xs text-gray-500">
            127.0.0.1 accepts local connections only. Enter the server's private or VPN IPv4 address for a remote Portainer server. 0.0.0.0 listens on every IPv4 interface.
          </p>
          <.input
            field={@form[:agent_secret]}
            type="password"
            label="Agent secret (optional)"
            autocomplete="new-password"
          />
          <p class="text-xs text-gray-500">
            If your Portainer server uses AGENT_SECRET, enter the same value here. The secret is never shown again.
          </p>
          <button
            id="install-portainer"
            type="submit"
            disabled={@busy}
            phx-disable-with="Installing…"
            class="rounded-lg bg-indigo-600 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-indigo-500 disabled:opacity-50"
          >
            Install agent
          </button>
        </.form>
        <div class="rounded-xl border border-gray-200 p-6 dark:border-gray-800">
          <h2 class="font-semibold text-gray-900 dark:text-white">Connect from Portainer</h2>
          <p class="mt-2 text-sm text-gray-500">
            In Portainer, add a Docker Standalone environment, choose Agent, and enter this server's reachable address followed by :9001. A running container does not confirm the Portainer connection.
          </p>
          <button
            :if={@agent && @agent["installed"]}
            id="remove-portainer"
            phx-click="remove"
            data-confirm="Remove the Hostctl-managed Portainer agent? Other containers and volumes will be kept."
            disabled={@busy}
            class="mt-5 rounded-lg border border-red-200 px-3 py-2 text-sm text-red-600 transition hover:bg-red-50 disabled:opacity-50"
          >
            Remove agent
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
