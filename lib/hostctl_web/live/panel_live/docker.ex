defmodule HostctlWeb.PanelLive.Docker do
  use HostctlWeb, :live_view

  alias Hostctl.Docker
  alias Hostctl.Hosting
  alias Hostctl.Hosting.DomainProxy

  @impl true
  def mount(_params, _session, socket) do
    domains = Hosting.list_all_domains_with_users()
    proxies = Hosting.list_domain_proxies_for_admin()

    {docker_status, containers} = load_containers()
    all_containers = load_all_containers()

    form =
      %DomainProxy{}
      |> Hosting.change_domain_proxy(default_proxy_params(domains, containers))
      |> to_form(as: :domain_proxy)

    {:ok,
     socket
     |> assign(:page_title, "Docker")
     |> assign(:active_tab, :panel_docker)
     |> assign(:tab, "containers")
     |> assign(:domains, domains)
     |> assign(:containers, containers)
     |> assign(:docker_status, docker_status)
     |> assign(:proxy_form, form)
     |> assign(:proxies_empty?, proxies == [])
     |> assign(:inspecting, nil)
     |> stream(:all_containers, all_containers)
     |> stream(:proxies, proxies)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab)}
  end

  @impl true
  def handle_event("refresh_containers", _params, socket) do
    {docker_status, containers} = load_containers()
    all_containers = load_all_containers()

    proxy_form =
      %DomainProxy{}
      |> Hosting.change_domain_proxy(default_proxy_params(socket.assigns.domains, containers))
      |> to_form(as: :domain_proxy)

    {:noreply,
     socket
     |> assign(:docker_status, docker_status)
     |> assign(:containers, containers)
     |> assign(:proxy_form, proxy_form)
     |> assign(:inspecting, nil)
     |> stream(:all_containers, all_containers, reset: true)}
  end

  @impl true
  def handle_event("start_container", %{"id" => container_id}, socket) do
    case Docker.start_container(container_id) do
      :ok ->
        {docker_status, containers} = load_containers()
        all_containers = load_all_containers()

        {:noreply,
         socket
         |> assign(:docker_status, docker_status)
         |> assign(:containers, containers)
         |> stream(:all_containers, all_containers, reset: true)
         |> put_flash(:info, "Container #{container_id} started.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("stop_container", %{"id" => container_id}, socket) do
    case Docker.stop_container(container_id) do
      :ok ->
        {docker_status, containers} = load_containers()
        all_containers = load_all_containers()

        {:noreply,
         socket
         |> assign(:docker_status, docker_status)
         |> assign(:containers, containers)
         |> stream(:all_containers, all_containers, reset: true)
         |> put_flash(:info, "Container #{container_id} stopped.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("restart_container", %{"id" => container_id}, socket) do
    case Docker.restart_container(container_id) do
      :ok ->
        {docker_status, containers} = load_containers()
        all_containers = load_all_containers()

        {:noreply,
         socket
         |> assign(:docker_status, docker_status)
         |> assign(:containers, containers)
         |> stream(:all_containers, all_containers, reset: true)
         |> put_flash(:info, "Container #{container_id} restarted.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("inspect_container", %{"id" => container_id}, socket) do
    case Docker.inspect_container(container_id) do
      {:ok, details} ->
        {:noreply, assign(socket, :inspecting, details)}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("close_inspect", _params, socket) do
    {:noreply, assign(socket, :inspecting, nil)}
  end

  @impl true
  def handle_event("validate_proxy", %{"domain_proxy" => params}, socket) do
    form =
      %DomainProxy{}
      |> Hosting.change_domain_proxy(params)
      |> to_form(action: :validate, as: :domain_proxy)

    {:noreply, assign(socket, :proxy_form, form)}
  end

  @impl true
  def handle_event("create_proxy", %{"domain_proxy" => params}, socket) do
    case Hosting.create_domain_proxy(params) do
      {:ok, proxy} ->
        {:noreply,
         socket
         |> assign(:proxies_empty?, false)
         |> assign(
           :proxy_form,
           to_form(
             Hosting.change_domain_proxy(
               %DomainProxy{},
               default_proxy_params(socket.assigns.domains, socket.assigns.containers)
             ),
             as: :domain_proxy
           )
         )
         |> stream_insert(:proxies, proxy)
         |> put_flash(:info, "Proxy mapping created and Nginx reloaded.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :proxy_form, to_form(changeset, as: :domain_proxy))}
    end
  end

  @impl true
  def handle_event("delete_proxy", %{"id" => id}, socket) do
    proxy = Hosting.get_domain_proxy_for_admin!(id)
    {:ok, _deleted} = Hosting.delete_domain_proxy(proxy)

    remaining = Hosting.list_domain_proxies_for_admin()

    {:noreply,
     socket
     |> assign(:proxies_empty?, remaining == [])
     |> stream_delete(:proxies, proxy)
     |> put_flash(:info, "Proxy mapping removed and Nginx reloaded.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="max-w-6xl mx-auto space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Docker</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Manage containers and proxy them to domain paths.
            </p>
          </div>
          <button
            id="docker-refresh-btn"
            phx-click="refresh_containers"
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Refresh
          </button>
        </div>

        <%!-- Status badge --%>
        <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-5">
          <div class="flex items-start gap-3">
            <div class={[
              "mt-0.5 flex items-center justify-center w-8 h-8 rounded-lg",
              if(@docker_status == :ok,
                do: "bg-sky-100 dark:bg-sky-900/40 text-sky-700 dark:text-sky-300",
                else: "bg-amber-100 dark:bg-amber-900/40 text-amber-700 dark:text-amber-300"
              )
            ]}>
              <.icon name="hero-cube" class="w-4 h-4" />
            </div>
            <div class="space-y-1">
              <%= if @docker_status == :ok do %>
                <p class="text-sm font-medium text-gray-900 dark:text-white">
                  Docker daemon is reachable.
                </p>
                <p class="text-xs text-gray-500 dark:text-gray-400">
                  Found {length(@containers)} running container(s).
                </p>
              <% else %>
                <p class="text-sm font-medium text-amber-700 dark:text-amber-300">
                  Docker is currently unavailable.
                </p>
                <p class="text-xs text-amber-600 dark:text-amber-400">
                  Install Docker from the Features page, or start the daemon manually.
                </p>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Tab bar --%>
        <div class="flex gap-1 border-b border-gray-200 dark:border-gray-800">
          <button
            phx-click="switch_tab"
            phx-value-tab="containers"
            class={[
              "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors -mb-px",
              if(@tab == "containers",
                do:
                  "border-b-2 border-indigo-600 text-indigo-600 dark:text-indigo-400 dark:border-indigo-400",
                else:
                  "text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300 border-b-2 border-transparent"
              )
            ]}
          >
            <.icon name="hero-server-stack" class="w-4 h-4 inline mr-1 -mt-0.5" /> Containers
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="proxies"
            class={[
              "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors -mb-px",
              if(@tab == "proxies",
                do:
                  "border-b-2 border-indigo-600 text-indigo-600 dark:text-indigo-400 dark:border-indigo-400",
                else:
                  "text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300 border-b-2 border-transparent"
              )
            ]}
          >
            <.icon name="hero-link" class="w-4 h-4 inline mr-1 -mt-0.5" /> Proxy Mappings
          </button>
        </div>

        <%!-- ============= Containers tab ============= --%>
        <div :if={@tab == "containers"} class="space-y-4">
          <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 overflow-hidden">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h2 class="text-base font-semibold text-gray-900 dark:text-white">All Containers</h2>
            </div>

            <div id="docker-containers" phx-update="stream">
              <div class="hidden only:block py-16 text-center text-gray-400 dark:text-gray-500">
                No containers found. Pull an image and start a container to get started.
              </div>

              <div
                :for={{dom_id, container} <- @streams.all_containers}
                id={dom_id}
                class="flex items-center gap-4 px-6 py-4 border-b border-gray-100 dark:border-gray-800 last:border-b-0"
              >
                <div class={[
                  "flex items-center justify-center w-9 h-9 rounded-lg shrink-0",
                  if(running?(container),
                    do: "bg-green-100 dark:bg-green-900/40 text-green-600 dark:text-green-400",
                    else: "bg-gray-100 dark:bg-gray-800 text-gray-500 dark:text-gray-400"
                  )
                ]}>
                  <.icon
                    name={if(running?(container), do: "hero-play", else: "hero-stop")}
                    class="w-4 h-4"
                  />
                </div>

                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium text-gray-900 dark:text-white truncate">
                    {container.name}
                  </p>
                  <p class="text-xs text-gray-500 dark:text-gray-400 truncate">
                    {container.image}
                    <span :if={container.ports != ""} class="text-gray-400 dark:text-gray-600">
                      &bull; {container.ports}
                    </span>
                  </p>
                </div>

                <span class={[
                  "hidden sm:inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium shrink-0",
                  if(running?(container),
                    do: "bg-green-100 dark:bg-green-900/40 text-green-700 dark:text-green-400",
                    else: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400"
                  )
                ]}>
                  {container.status}
                </span>

                <div class="flex items-center gap-1.5 shrink-0">
                  <%= if running?(container) do %>
                    <button
                      id={"stop-#{container.id}"}
                      phx-click="stop_container"
                      phx-value-id={container.name}
                      data-confirm={"Stop container #{container.name}?"}
                      class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-amber-50 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300 hover:bg-amber-100 dark:hover:bg-amber-900/50 text-xs font-medium transition-colors"
                    >
                      <.icon name="hero-stop" class="w-3.5 h-3.5" /> Stop
                    </button>
                    <button
                      id={"restart-#{container.id}"}
                      phx-click="restart_container"
                      phx-value-id={container.name}
                      class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 hover:bg-blue-100 dark:hover:bg-blue-900/50 text-xs font-medium transition-colors"
                    >
                      <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Restart
                    </button>
                  <% else %>
                    <button
                      id={"start-#{container.id}"}
                      phx-click="start_container"
                      phx-value-id={container.name}
                      class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-green-50 dark:bg-green-900/30 text-green-700 dark:text-green-300 hover:bg-green-100 dark:hover:bg-green-900/50 text-xs font-medium transition-colors"
                    >
                      <.icon name="hero-play" class="w-3.5 h-3.5" /> Start
                    </button>
                  <% end %>
                  <button
                    id={"inspect-#{container.id}"}
                    phx-click="inspect_container"
                    phx-value-id={container.name}
                    class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 text-xs font-medium transition-colors"
                  >
                    <.icon name="hero-eye" class="w-3.5 h-3.5" /> Inspect
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Inspect panel --%>
          <%= if @inspecting do %>
            <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 overflow-hidden">
              <div class="flex items-center justify-between px-6 py-4 border-b border-gray-200 dark:border-gray-800">
                <h2 class="text-base font-semibold text-gray-900 dark:text-white">
                  Inspecting: {@inspecting.name}
                </h2>
                <button
                  id="close-inspect-btn"
                  phx-click="close_inspect"
                  class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 transition-colors"
                >
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              </div>

              <div class="p-6 space-y-4">
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <div>
                    <p class="text-xs font-medium uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-1">
                      Image
                    </p>
                    <p class="text-sm text-gray-900 dark:text-white font-mono">
                      {@inspecting.image}
                    </p>
                  </div>
                  <div>
                    <p class="text-xs font-medium uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-1">
                      State
                    </p>
                    <span class={[
                      "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                      if(@inspecting.state == "running",
                        do: "bg-green-100 dark:bg-green-900/40 text-green-700 dark:text-green-400",
                        else: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400"
                      )
                    ]}>
                      {@inspecting.state}
                    </span>
                  </div>
                  <div>
                    <p class="text-xs font-medium uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-1">
                      Container ID
                    </p>
                    <p class="text-sm text-gray-900 dark:text-white font-mono truncate">
                      {@inspecting.id}
                    </p>
                  </div>
                  <div>
                    <p class="text-xs font-medium uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-1">
                      Published Ports
                    </p>
                    <p class="text-sm text-gray-900 dark:text-white font-mono">
                      {format_ports(@inspecting.ports)}
                    </p>
                  </div>
                </div>

                <div :if={@inspecting.env != %{}}>
                  <p class="text-xs font-medium uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-2">
                    Environment Variables
                  </p>
                  <div class="rounded-lg bg-gray-50 dark:bg-gray-800/50 border border-gray-200 dark:border-gray-700 overflow-auto max-h-64">
                    <table class="min-w-full text-sm">
                      <tbody>
                        <tr
                          :for={{key, val} <- Enum.sort(@inspecting.env)}
                          class="border-b border-gray-200 dark:border-gray-700 last:border-b-0"
                        >
                          <td class="px-4 py-2 font-mono text-xs text-indigo-700 dark:text-indigo-400 whitespace-nowrap align-top font-medium">
                            {key}
                          </td>
                          <td class="px-4 py-2 font-mono text-xs text-gray-700 dark:text-gray-300 break-all">
                            {val}
                          </td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- ============= Proxies tab ============= --%>
        <div :if={@tab == "proxies"} class="space-y-4">
          <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-6">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white mb-4">
              Create Proxy Mapping
            </h2>

            <.form
              for={@proxy_form}
              id="docker-proxy-form"
              phx-change="validate_proxy"
              phx-submit="create_proxy"
              class="grid grid-cols-1 md:grid-cols-2 gap-4"
            >
              <.input
                field={@proxy_form[:domain_id]}
                type="select"
                label="Domain"
                options={domain_options(@domains)}
              />

              <.input
                field={@proxy_form[:container_name]}
                type="select"
                label="Container"
                options={container_options(@containers)}
              />

              <.input
                field={@proxy_form[:path]}
                type="text"
                label="Domain Path"
                placeholder="/app"
              />

              <.input
                field={@proxy_form[:upstream_port]}
                type="number"
                min="1"
                max="65535"
                label="Published Host Port"
                placeholder="3000"
              />

              <.input field={@proxy_form[:enabled]} type="checkbox" label="Enabled" />

              <div class="md:col-span-2">
                <button
                  id="create-domain-proxy-btn"
                  type="submit"
                  class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> Create Mapping
                </button>
              </div>
            </.form>
          </div>

          <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 overflow-hidden">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h2 class="text-base font-semibold text-gray-900 dark:text-white">
                Active Mappings
              </h2>
            </div>

            <%= if @proxies_empty? do %>
              <div
                id="domain-proxy-empty"
                class="py-16 text-center text-gray-500 dark:text-gray-400"
              >
                No proxy mappings yet.
              </div>
            <% end %>

            <div id="domain-proxies-list" phx-update="stream">
              <div
                :for={{id, proxy} <- @streams.proxies}
                id={id}
                class="flex items-center gap-4 px-6 py-4 border-b border-gray-100 dark:border-gray-800 last:border-b-0"
              >
                <div class="flex items-center justify-center w-9 h-9 rounded-lg bg-indigo-100 dark:bg-indigo-900/40 text-indigo-600 dark:text-indigo-400 shrink-0">
                  <.icon name="hero-link" class="w-4 h-4" />
                </div>

                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium text-gray-900 dark:text-white truncate">
                    {proxy.domain.name}{proxy.path}
                  </p>
                  <p class="text-xs text-gray-500 dark:text-gray-400 truncate">
                    {proxy.container_name} -> 127.0.0.1:{proxy.upstream_port}
                    <span class="text-gray-400 dark:text-gray-600">&nbsp;&bull;&nbsp;</span>
                    {proxy.domain.user.email}
                  </p>
                </div>

                <div class="flex items-center gap-3 shrink-0">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
                    if(proxy.enabled,
                      do: "bg-green-100 dark:bg-green-900/40 text-green-700 dark:text-green-400",
                      else: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300"
                    )
                  ]}>
                    {if proxy.enabled, do: "Enabled", else: "Disabled"}
                  </span>

                  <button
                    id={"delete-domain-proxy-#{proxy.id}"}
                    phx-click="delete_proxy"
                    phx-value-id={proxy.id}
                    data-confirm="Remove this proxy mapping?"
                    class="inline-flex items-center gap-1 px-3 py-1.5 rounded-md bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-900/50 text-xs font-medium transition-colors"
                  >
                    <.icon name="hero-trash" class="w-3.5 h-3.5" /> Remove
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_containers do
    case Docker.list_containers() do
      {:ok, containers} -> {:ok, containers}
      {:error, _reason} -> {:error, []}
    end
  end

  defp load_all_containers do
    case Docker.list_all_containers() do
      {:ok, containers} -> containers
      {:error, _} -> []
    end
  end

  defp running?(container) do
    String.starts_with?(String.downcase(container.status), "up")
  end

  defp format_ports(ports) when ports == %{}, do: "None"

  defp format_ports(ports) when is_map(ports) do
    ports
    |> Enum.map(fn {port_proto, host_ports} ->
      "#{Enum.join(host_ports, ",")}->#{port_proto}"
    end)
    |> Enum.join(", ")
  end

  defp domain_options(domains) do
    Enum.map(domains, fn domain ->
      {"#{domain.name} (#{domain.user.email})", domain.id}
    end)
  end

  defp container_options([]), do: [{"No running containers detected", ""}]

  defp container_options(containers) do
    Enum.map(containers, fn container ->
      port_hint =
        case container.published_ports do
          [] -> "no published ports"
          ports -> Enum.join(ports, ",")
        end

      {"#{container.name} (#{container.image}) [#{port_hint}]", container.name}
    end)
  end

  defp default_proxy_params(domains, containers) do
    domain_id = domains |> List.first() |> then(&if(&1, do: &1.id, else: nil))

    container = List.first(containers)

    port =
      case container do
        %{published_ports: [first | _]} -> first
        _ -> 3000
      end

    %{
      "domain_id" => domain_id,
      "path" => "/app",
      "container_name" => if(container, do: container.name, else: ""),
      "upstream_port" => port,
      "enabled" => true
    }
  end
end
