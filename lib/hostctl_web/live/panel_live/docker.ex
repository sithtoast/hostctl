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

    form =
      %DomainProxy{}
      |> Hosting.change_domain_proxy(default_proxy_params(domains, containers))
      |> to_form(as: :domain_proxy)

    {:ok,
     socket
     |> assign(:page_title, "Docker Proxy")
     |> assign(:active_tab, :panel_docker)
     |> assign(:domains, domains)
     |> assign(:containers, containers)
     |> assign(:docker_status, docker_status)
     |> assign(:proxy_form, form)
     |> assign(:proxies_empty?, proxies == [])
     |> stream(:proxies, proxies)}
  end

  @impl true
  def handle_event("refresh_containers", _params, socket) do
    {docker_status, containers} = load_containers()

    proxy_form =
      %DomainProxy{}
      |> Hosting.change_domain_proxy(default_proxy_params(socket.assigns.domains, containers))
      |> to_form(as: :domain_proxy)

    {:noreply,
     socket
     |> assign(:docker_status, docker_status)
     |> assign(:containers, containers)
     |> assign(:proxy_form, proxy_form)}
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
        <div class="flex items-center justify-between gap-4 flex-wrap">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Docker Proxy</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Route domain subpaths to Docker containers running on this server.
            </p>
          </div>
          <button
            id="docker-refresh-btn"
            phx-click="refresh_containers"
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Refresh Containers
          </button>
        </div>

        <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-5">
          <div class="flex items-start gap-3">
            <div class="mt-0.5 flex items-center justify-center w-8 h-8 rounded-lg bg-sky-100 dark:bg-sky-900/40 text-sky-700 dark:text-sky-300">
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
                  Start Docker and ensure hostctl can run docker commands before creating mappings.
                </p>
              <% end %>
            </div>
          </div>
        </div>

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
            <h2 class="text-base font-semibold text-gray-900 dark:text-white">Active Mappings</h2>
          </div>

          <%= if @proxies_empty? do %>
            <div id="domain-proxy-empty" class="py-16 text-center text-gray-500 dark:text-gray-400">
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
    </Layouts.app>
    """
  end

  defp load_containers do
    case Docker.list_containers() do
      {:ok, containers} -> {:ok, containers}
      {:error, _reason} -> {:error, []}
    end
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
