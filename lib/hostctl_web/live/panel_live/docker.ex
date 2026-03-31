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

    compose_stacks = load_compose_stacks()

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
     |> assign(:pull_image_name, "")
     |> assign(:pulling, false)
     |> assign(:search_query, "")
     |> assign(:search_results, nil)
     |> assign(:compose_stacks, compose_stacks)
     |> assign(:show_run_form, false)
     |> assign(:run_env_count, 1)
     |> assign(:images, load_images())
     |> assign(:deploy_image, nil)
     |> assign(:deploy_env_count, 1)
     |> assign(:editing, nil)
     |> assign(:edit_env_count, 0)
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
     |> assign(:compose_stacks, load_compose_stacks())
     |> assign(:images, load_images())
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
  def handle_event("edit_container", %{"id" => container_name}, socket) do
    case Docker.inspect_container(container_name) do
      {:ok, details} ->
        env_count = max(map_size(details.env), 1)

        {:noreply,
         socket
         |> assign(:editing, details)
         |> assign(:edit_env_count, env_count)
         |> assign(:inspecting, nil)}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  @impl true
  def handle_event("add_edit_env_row", _params, socket) do
    {:noreply, assign(socket, :edit_env_count, socket.assigns.edit_env_count + 1)}
  end

  @impl true
  def handle_event("save_container_edit", params, socket) do
    editing = socket.assigns.editing
    new_name = String.trim(params["name"] || "")
    restart = String.trim(params["restart"] || "")

    ports =
      (params["ports"] || "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    env = parse_env_pairs(params, "edit_env_key_", "edit_env_val_")

    opts =
      [ports: ports, env: env] ++
        if(new_name != "", do: [name: new_name], else: []) ++
        if(restart != "", do: [restart: restart], else: [])

    case Docker.recreate_container(editing.name, opts) do
      {:ok, _new_id} ->
        {docker_status, containers} = load_containers()
        all_containers = load_all_containers()

        {:noreply,
         socket
         |> assign(:docker_status, docker_status)
         |> assign(:containers, containers)
         |> assign(:editing, nil)
         |> stream(:all_containers, all_containers, reset: true)
         |> put_flash(:info, "Container recreated with updated settings.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("toggle_run_form", _params, socket) do
    {:noreply, assign(socket, :show_run_form, !socket.assigns.show_run_form)}
  end

  @impl true
  def handle_event("add_env_row", _params, socket) do
    {:noreply, assign(socket, :run_env_count, socket.assigns.run_env_count + 1)}
  end

  @impl true
  def handle_event("run_container", params, socket) do
    image = String.trim(params["image"] || "")
    name = String.trim(params["name"] || "")
    restart = String.trim(params["restart"] || "")

    if image == "" do
      {:noreply, put_flash(socket, :error, "Image name is required.")}
    else
      ports =
        (params["ports"] || "")
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      env =
        parse_env_pairs(params)

      opts =
        [name: name, ports: ports, env: env, restart: restart]
        |> Enum.reject(fn {_k, v} -> v == "" or v == [] end)

      case Docker.run_container(image, opts) do
        {:ok, _container_id} ->
          {docker_status, containers} = load_containers()
          all_containers = load_all_containers()

          {:noreply,
           socket
           |> assign(:docker_status, docker_status)
           |> assign(:containers, containers)
           |> assign(:show_run_form, false)
           |> assign(:run_env_count, 1)
           |> stream(:all_containers, all_containers, reset: true)
           |> put_flash(:info, "Container started from #{image}.")}

        {:error, msg} ->
          {:noreply, put_flash(socket, :error, msg)}
      end
    end
  end

  @impl true
  def handle_event("search_registry", %{"search_query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, :search_results, nil)}
    else
      case Docker.search_registry(query) do
        {:ok, results} ->
          {:noreply, assign(socket, search_results: results, search_query: query)}

        {:error, msg} ->
          {:noreply, put_flash(socket, :error, msg)}
      end
    end
  end

  @impl true
  def handle_event("pull_image", %{"image_name" => image_name}, socket) do
    image_name = String.trim(image_name)

    if image_name == "" do
      {:noreply, put_flash(socket, :error, "Please enter an image name.")}
    else
      socket = assign(socket, :pulling, true)

      case Docker.pull_image(image_name) do
        {:ok, _output} ->
          all_containers = load_all_containers()

          {:noreply,
           socket
           |> assign(:pulling, false)
           |> assign(:pull_image_name, "")
           |> assign(:images, load_images())
           |> stream(:all_containers, all_containers, reset: true)
           |> put_flash(:info, "Image #{image_name} pulled successfully.")}

        {:error, msg} ->
          {:noreply,
           socket
           |> assign(:pulling, false)
           |> put_flash(:error, msg)}
      end
    end
  end

  @impl true
  def handle_event("pull_search_result", %{"name" => image_name}, socket) do
    socket = assign(socket, :pulling, true)

    case Docker.pull_image(image_name) do
      {:ok, _output} ->
        all_containers = load_all_containers()

        {:noreply,
         socket
         |> assign(:pulling, false)
         |> assign(:images, load_images())
         |> stream(:all_containers, all_containers, reset: true)
         |> put_flash(:info, "Image #{image_name} pulled successfully.")}

      {:error, msg} ->
        {:noreply,
         socket
         |> assign(:pulling, false)
         |> put_flash(:error, msg)}
    end
  end

  @impl true
  def handle_event("deploy_image", %{"image" => image_ref}, socket) do
    {:noreply, assign(socket, deploy_image: image_ref, deploy_env_count: 1)}
  end

  @impl true
  def handle_event("cancel_deploy", _params, socket) do
    {:noreply, assign(socket, :deploy_image, nil)}
  end

  @impl true
  def handle_event("add_deploy_env_row", _params, socket) do
    {:noreply, assign(socket, :deploy_env_count, socket.assigns.deploy_env_count + 1)}
  end

  @impl true
  def handle_event("run_from_image", params, socket) do
    image = socket.assigns.deploy_image
    name = String.trim(params["name"] || "")
    restart = String.trim(params["restart"] || "")

    ports =
      (params["ports"] || "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    env = parse_env_pairs(params, "deploy_env_key_", "deploy_env_val_")

    opts =
      [name: name, ports: ports, env: env, restart: restart]
      |> Enum.reject(fn {_k, v} -> v == "" or v == [] end)

    case Docker.run_container(image, opts) do
      {:ok, _container_id} ->
        {docker_status, containers} = load_containers()
        all_containers = load_all_containers()

        {:noreply,
         socket
         |> assign(:docker_status, docker_status)
         |> assign(:containers, containers)
         |> assign(:deploy_image, nil)
         |> assign(:deploy_env_count, 1)
         |> assign(:tab, "containers")
         |> stream(:all_containers, all_containers, reset: true)
         |> put_flash(:info, "Container started from #{image}.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("remove_image", %{"id" => image_id}, socket) do
    case Docker.remove_image(image_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:images, load_images())
         |> put_flash(:info, "Image removed.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("remove_container", %{"id" => container_id}, socket) do
    case Docker.remove_container(container_id) do
      :ok ->
        {docker_status, containers} = load_containers()
        all_containers = load_all_containers()

        {:noreply,
         socket
         |> assign(:docker_status, docker_status)
         |> assign(:containers, containers)
         |> stream(:all_containers, all_containers, reset: true)
         |> put_flash(:info, "Container #{container_id} removed.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("compose_up", %{"name" => name}, socket) do
    case Docker.compose_up(name) do
      :ok ->
        {docker_status, containers} = load_containers()
        all_containers = load_all_containers()

        {:noreply,
         socket
         |> assign(:docker_status, docker_status)
         |> assign(:containers, containers)
         |> assign(:compose_stacks, load_compose_stacks())
         |> stream(:all_containers, all_containers, reset: true)
         |> put_flash(:info, "Compose stack \"#{name}\" started.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("compose_down", %{"name" => name}, socket) do
    case Docker.compose_down(name) do
      :ok ->
        {docker_status, containers} = load_containers()
        all_containers = load_all_containers()

        {:noreply,
         socket
         |> assign(:docker_status, docker_status)
         |> assign(:containers, containers)
         |> assign(:compose_stacks, load_compose_stacks())
         |> stream(:all_containers, all_containers, reset: true)
         |> put_flash(:info, "Compose stack \"#{name}\" stopped.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_event("compose_restart", %{"name" => name}, socket) do
    case Docker.compose_restart(name) do
      :ok ->
        {:noreply,
         socket
         |> assign(:compose_stacks, load_compose_stacks())
         |> put_flash(:info, "Compose stack \"#{name}\" restarted.")}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
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
          <button
            phx-click="switch_tab"
            phx-value-tab="images"
            class={[
              "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors -mb-px",
              if(@tab == "images",
                do:
                  "border-b-2 border-indigo-600 text-indigo-600 dark:text-indigo-400 dark:border-indigo-400",
                else:
                  "text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300 border-b-2 border-transparent"
              )
            ]}
          >
            <.icon name="hero-arrow-down-tray" class="w-4 h-4 inline mr-1 -mt-0.5" /> Images
          </button>
          <button
            phx-click="switch_tab"
            phx-value-tab="compose"
            class={[
              "px-4 py-2 text-sm font-medium rounded-t-lg transition-colors -mb-px",
              if(@tab == "compose",
                do:
                  "border-b-2 border-indigo-600 text-indigo-600 dark:text-indigo-400 dark:border-indigo-400",
                else:
                  "text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-300 border-b-2 border-transparent"
              )
            ]}
          >
            <.icon name="hero-square-3-stack-3d" class="w-4 h-4 inline mr-1 -mt-0.5" /> Compose
          </button>
        </div>

        <%!-- ============= Containers tab ============= --%>
        <div :if={@tab == "containers"} class="space-y-4">
          <%!-- Run new container --%>
          <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 overflow-hidden">
            <button
              id="toggle-run-form-btn"
              phx-click="toggle_run_form"
              class="w-full flex items-center justify-between px-6 py-4 text-left hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
            >
              <div class="flex items-center gap-2">
                <.icon name="hero-plus-circle" class="w-5 h-5 text-indigo-600 dark:text-indigo-400" />
                <span class="text-sm font-semibold text-gray-900 dark:text-white">
                  Run New Container
                </span>
              </div>
              <.icon
                name={if(@show_run_form, do: "hero-chevron-up", else: "hero-chevron-down")}
                class="w-4 h-4 text-gray-400"
              />
            </button>

            <div :if={@show_run_form} class="px-6 pb-6 border-t border-gray-200 dark:border-gray-800">
              <form id="run-container-form" phx-submit="run_container" class="space-y-4 pt-4">
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Image <span class="text-red-500">*</span>
                    </label>
                    <input
                      type="text"
                      name="image"
                      placeholder="e.g. nginx:latest, postgres:16"
                      required
                      class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                    />
                  </div>
                  <div>
                    <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Container Name
                    </label>
                    <input
                      type="text"
                      name="name"
                      placeholder="e.g. my-app"
                      class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                    />
                  </div>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Ports
                    </label>
                    <textarea
                      name="ports"
                      rows="2"
                      placeholder="One per line, e.g.&#10;8080:80&#10;5432:5432"
                      class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 font-mono focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                    />
                    <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                      host:container format, one per line
                    </p>
                  </div>
                  <div>
                    <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Restart Policy
                    </label>
                    <select
                      name="restart"
                      class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                    >
                      <option value="">None (default)</option>
                      <option value="always">Always</option>
                      <option value="unless-stopped">Unless Stopped</option>
                      <option value="on-failure">On Failure</option>
                    </select>
                  </div>
                </div>

                <div>
                  <div class="flex items-center justify-between mb-2">
                    <label class="block text-sm font-medium text-gray-700 dark:text-gray-300">
                      Environment Variables
                    </label>
                    <button
                      type="button"
                      id="add-env-row-btn"
                      phx-click="add_env_row"
                      class="inline-flex items-center gap-1 px-2 py-1 rounded text-xs font-medium text-indigo-600 dark:text-indigo-400 hover:bg-indigo-50 dark:hover:bg-indigo-900/30 transition-colors"
                    >
                      <.icon name="hero-plus" class="w-3 h-3" /> Add Row
                    </button>
                  </div>
                  <div class="space-y-2">
                    <div :for={i <- 0..(@run_env_count - 1)} class="flex gap-2">
                      <input
                        type="text"
                        name={"env_key_#{i}"}
                        placeholder="KEY"
                        class="w-1/3 rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 font-mono focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                      />
                      <input
                        type="text"
                        name={"env_val_#{i}"}
                        placeholder="value"
                        class="flex-1 rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 font-mono focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                      />
                    </div>
                  </div>
                </div>

                <div>
                  <button
                    id="run-container-btn"
                    type="submit"
                    class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
                  >
                    <.icon name="hero-play" class="w-4 h-4" /> Run Container
                  </button>
                </div>
              </form>
            </div>
          </div>

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
                    <button
                      id={"remove-#{container.id}"}
                      phx-click="remove_container"
                      phx-value-id={container.name}
                      data-confirm={"Remove container #{container.name}? This cannot be undone."}
                      class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-900/50 text-xs font-medium transition-colors"
                    >
                      <.icon name="hero-trash" class="w-3.5 h-3.5" /> Remove
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
                  <button
                    id={"edit-#{container.id}"}
                    phx-click="edit_container"
                    phx-value-id={container.name}
                    class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-indigo-50 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-100 dark:hover:bg-indigo-900/50 text-xs font-medium transition-colors"
                  >
                    <.icon name="hero-pencil-square" class="w-3.5 h-3.5" /> Edit
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

          <%!-- Edit panel --%>
          <%= if @editing do %>
            <div class="rounded-xl border border-indigo-200 dark:border-indigo-800 bg-white dark:bg-gray-900 overflow-hidden">
              <div class="flex items-center justify-between px-6 py-4 border-b border-indigo-200 dark:border-indigo-800 bg-indigo-50 dark:bg-indigo-900/20">
                <h2 class="text-base font-semibold text-gray-900 dark:text-white">
                  Edit: {@editing.name}
                </h2>
                <button
                  id="cancel-edit-btn"
                  phx-click="cancel_edit"
                  class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 transition-colors"
                >
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              </div>

              <form id="edit-container-form" phx-submit="save_container_edit" class="p-6 space-y-5">
                <div class="rounded-lg bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 px-4 py-3">
                  <p class="text-xs text-amber-800 dark:text-amber-300">
                    <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline -mt-0.5 mr-1" />
                    Saving will recreate the container with the updated settings. The container will be briefly stopped during this process.
                  </p>
                </div>

                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <div>
                    <label
                      for="edit-container-name"
                      class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
                    >
                      Container Name
                    </label>
                    <input
                      type="text"
                      id="edit-container-name"
                      name="name"
                      value={@editing.name}
                      class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                    />
                  </div>
                  <div>
                    <label
                      for="edit-restart-policy"
                      class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
                    >
                      Restart Policy
                    </label>
                    <select
                      id="edit-restart-policy"
                      name="restart"
                      class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                    >
                      <option value="no" selected={@editing.restart_policy == "no"}>no</option>
                      <option value="always" selected={@editing.restart_policy == "always"}>
                        always
                      </option>
                      <option
                        value="unless-stopped"
                        selected={@editing.restart_policy == "unless-stopped"}
                      >
                        unless-stopped
                      </option>
                      <option
                        value="on-failure"
                        selected={@editing.restart_policy == "on-failure"}
                      >
                        on-failure
                      </option>
                    </select>
                  </div>
                </div>

                <div>
                  <label
                    for="edit-container-ports"
                    class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1"
                  >
                    Port Mappings
                    <span class="text-gray-400 font-normal">(one per line, e.g. 8080:80)</span>
                  </label>
                  <textarea
                    id="edit-container-ports"
                    name="ports"
                    rows="3"
                    class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 px-3 py-2 text-sm font-mono text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                    placeholder="8080:80"
                  >{format_port_lines(@editing.ports)}</textarea>
                </div>

                <div>
                  <div class="flex items-center justify-between mb-2">
                    <label class="block text-sm font-medium text-gray-700 dark:text-gray-300">
                      Environment Variables
                    </label>
                    <button
                      type="button"
                      phx-click="add_edit_env_row"
                      class="inline-flex items-center gap-1 text-xs text-indigo-600 dark:text-indigo-400 hover:text-indigo-700 dark:hover:text-indigo-300 font-medium"
                    >
                      <.icon name="hero-plus" class="w-3.5 h-3.5" /> Add Variable
                    </button>
                  </div>
                  <div class="space-y-2">
                    <%= for i <- 0..(@edit_env_count - 1) do %>
                      <% env_list = Enum.sort(@editing.env)
                      {default_key, default_val} = Enum.at(env_list, i, {"", ""}) %>
                      <div class="flex gap-2">
                        <input
                          type="text"
                          name={"edit_env_key_#{i}"}
                          value={default_key}
                          placeholder="KEY"
                          class="flex-1 rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 px-3 py-2 text-sm font-mono text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                        />
                        <input
                          type="text"
                          name={"edit_env_val_#{i}"}
                          value={default_val}
                          placeholder="value"
                          class="flex-1 rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 px-3 py-2 text-sm font-mono text-gray-900 dark:text-white focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                        />
                      </div>
                    <% end %>
                  </div>
                </div>

                <div class="flex justify-end pt-2">
                  <button
                    type="submit"
                    id="save-container-edit-btn"
                    class="inline-flex items-center gap-2 px-5 py-2.5 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium shadow-sm transition-colors focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
                  >
                    <.icon name="hero-check" class="w-4 h-4" /> Save Changes
                  </button>
                </div>
              </form>
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

        <%!-- ============= Images tab ============= --%>
        <div :if={@tab == "images"} class="space-y-4">
          <%!-- Pull image --%>
          <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-6">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white mb-4">Pull Image</h2>

            <form id="pull-image-form" phx-submit="pull_image" class="flex gap-3">
              <div class="flex-1">
                <input
                  type="text"
                  name="image_name"
                  value={@pull_image_name}
                  placeholder="e.g. nginx:latest, postgres:16, myrepo/myapp:v2"
                  class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-4 py-2.5 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                />
              </div>
              <button
                id="pull-image-btn"
                type="submit"
                disabled={@pulling}
                class={[
                  "inline-flex items-center gap-2 px-5 py-2.5 rounded-lg text-sm font-medium transition-colors shrink-0",
                  if(@pulling,
                    do: "bg-indigo-400 text-white cursor-wait",
                    else: "bg-indigo-600 hover:bg-indigo-500 text-white"
                  )
                ]}
              >
                <%= if @pulling do %>
                  <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin" /> Pulling…
                <% else %>
                  <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Pull
                <% end %>
              </button>
            </form>
          </div>

          <%!-- Local images --%>
          <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 overflow-hidden">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h2 class="text-base font-semibold text-gray-900 dark:text-white">Local Images</h2>
              <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                Images available on this server. Deploy to run a new container.
              </p>
            </div>

            <%= if @images == [] do %>
              <div class="py-16 text-center text-gray-400 dark:text-gray-500 text-sm">
                No images found. Pull an image above or search Docker Hub.
              </div>
            <% else %>
              <div class="divide-y divide-gray-100 dark:divide-gray-800">
                <div :for={image <- @images} class="flex items-center gap-4 px-6 py-4">
                  <div class="flex items-center justify-center w-9 h-9 rounded-lg bg-violet-100 dark:bg-violet-900/40 text-violet-600 dark:text-violet-400 shrink-0">
                    <.icon name="hero-cube-transparent" class="w-4 h-4" />
                  </div>

                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium text-gray-900 dark:text-white truncate">
                      {image.repository}<span class="text-gray-400 dark:text-gray-500">:{image.tag}</span>
                    </p>
                    <p class="text-xs text-gray-500 dark:text-gray-400">
                      {image.size}
                      <span class="text-gray-400 dark:text-gray-600">&bull;</span>
                      {image.created}
                      <span class="text-gray-400 dark:text-gray-600">&bull;</span>
                      <span class="font-mono">{String.slice(image.id, 0..15)}</span>
                    </p>
                  </div>

                  <div class="flex items-center gap-1.5 shrink-0">
                    <button
                      id={"deploy-#{image.id}"}
                      phx-click="deploy_image"
                      phx-value-image={"#{image.repository}:#{image.tag}"}
                      class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-indigo-50 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-100 dark:hover:bg-indigo-900/50 text-xs font-medium transition-colors"
                    >
                      <.icon name="hero-rocket-launch" class="w-3.5 h-3.5" /> Deploy
                    </button>
                    <button
                      id={"remove-image-#{image.id}"}
                      phx-click="remove_image"
                      phx-value-id={image.id}
                      data-confirm={"Remove image #{image.repository}:#{image.tag}?"}
                      class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-red-50 dark:bg-red-900/30 text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-900/50 text-xs font-medium transition-colors"
                    >
                      <.icon name="hero-trash" class="w-3.5 h-3.5" />
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Deploy from image panel --%>
          <%= if @deploy_image do %>
            <div class="rounded-xl border-2 border-indigo-200 dark:border-indigo-800 bg-indigo-50/50 dark:bg-indigo-950/30 p-6">
              <div class="flex items-center justify-between mb-4">
                <div>
                  <h2 class="text-base font-semibold text-gray-900 dark:text-white">
                    Deploy: {@deploy_image}
                  </h2>
                  <p class="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                    Configure and run a new container from this image.
                  </p>
                </div>
                <button
                  id="cancel-deploy-btn"
                  phx-click="cancel_deploy"
                  class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 transition-colors"
                >
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              </div>

              <form id="run-from-image-form" phx-submit="run_from_image" class="space-y-4">
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Container Name
                    </label>
                    <input
                      type="text"
                      name="name"
                      placeholder="e.g. my-app"
                      class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                    />
                  </div>
                  <div>
                    <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                      Restart Policy
                    </label>
                    <select
                      name="restart"
                      class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500"
                    >
                      <option value="">None (default)</option>
                      <option value="always">Always</option>
                      <option value="unless-stopped">Unless Stopped</option>
                      <option value="on-failure">On Failure</option>
                    </select>
                  </div>
                </div>

                <div>
                  <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Ports
                  </label>
                  <textarea
                    name="ports"
                    rows="2"
                    placeholder="One per line, e.g.\n8080:80\n5432:5432"
                    class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 font-mono focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                  />
                  <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                    host:container format, one per line
                  </p>
                </div>

                <div>
                  <div class="flex items-center justify-between mb-2">
                    <label class="block text-sm font-medium text-gray-700 dark:text-gray-300">
                      Environment Variables
                    </label>
                    <button
                      type="button"
                      id="add-deploy-env-row-btn"
                      phx-click="add_deploy_env_row"
                      class="inline-flex items-center gap-1 px-2 py-1 rounded text-xs font-medium text-indigo-600 dark:text-indigo-400 hover:bg-indigo-50 dark:hover:bg-indigo-900/30 transition-colors"
                    >
                      <.icon name="hero-plus" class="w-3 h-3" /> Add Row
                    </button>
                  </div>
                  <div class="space-y-2">
                    <div :for={i <- 0..(@deploy_env_count - 1)} class="flex gap-2">
                      <input
                        type="text"
                        name={"deploy_env_key_#{i}"}
                        placeholder="KEY"
                        class="w-1/3 rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 font-mono focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                      />
                      <input
                        type="text"
                        name={"deploy_env_val_#{i}"}
                        placeholder="value"
                        class="flex-1 rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-3 py-2 font-mono focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                      />
                    </div>
                  </div>
                </div>

                <div>
                  <button
                    id="run-from-image-btn"
                    type="submit"
                    class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium transition-colors"
                  >
                    <.icon name="hero-rocket-launch" class="w-4 h-4" /> Deploy Container
                  </button>
                </div>
              </form>
            </div>
          <% end %>

          <%!-- Search registry --%>
          <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-6">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white mb-4">
              Search Docker Hub
            </h2>

            <form id="search-registry-form" phx-submit="search_registry" class="flex gap-3 mb-4">
              <div class="flex-1">
                <input
                  type="text"
                  name="search_query"
                  value={@search_query}
                  placeholder="Search for images…"
                  class="w-full rounded-lg border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-900 dark:text-white text-sm px-4 py-2.5 focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 placeholder:text-gray-400 dark:placeholder:text-gray-500"
                />
              </div>
              <button
                id="search-registry-btn"
                type="submit"
                class="inline-flex items-center gap-2 px-5 py-2.5 rounded-lg bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 text-sm font-medium transition-colors shrink-0"
              >
                <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Search
              </button>
            </form>

            <%= if @search_results do %>
              <div class="rounded-lg border border-gray-200 dark:border-gray-700 overflow-hidden">
                <%= if @search_results == [] do %>
                  <div class="py-10 text-center text-gray-400 dark:text-gray-500 text-sm">
                    No results found for "{@search_query}".
                  </div>
                <% else %>
                  <div class="divide-y divide-gray-200 dark:divide-gray-700">
                    <div
                      :for={result <- @search_results}
                      class="flex items-center gap-4 px-4 py-3"
                    >
                      <div class="flex-1 min-w-0">
                        <p class="text-sm font-medium text-gray-900 dark:text-white truncate">
                          {result.name}
                        </p>
                        <p class="text-xs text-gray-500 dark:text-gray-400 truncate">
                          {result.description}
                        </p>
                      </div>
                      <div class="flex items-center gap-3 shrink-0">
                        <span class="inline-flex items-center gap-1 text-xs text-amber-600 dark:text-amber-400">
                          <.icon name="hero-star" class="w-3.5 h-3.5" /> {result.stars}
                        </span>
                        <button
                          id={"pull-#{String.replace(result.name, "/", "-")}"}
                          phx-click="pull_search_result"
                          phx-value-name={result.name}
                          disabled={@pulling}
                          class={[
                            "inline-flex items-center gap-1 px-3 py-1.5 rounded-md text-xs font-medium transition-colors",
                            if(@pulling,
                              do:
                                "bg-gray-100 dark:bg-gray-800 text-gray-400 dark:text-gray-500 cursor-wait",
                              else:
                                "bg-indigo-50 dark:bg-indigo-900/30 text-indigo-700 dark:text-indigo-300 hover:bg-indigo-100 dark:hover:bg-indigo-900/50"
                            )
                          ]}
                        >
                          <.icon name="hero-arrow-down-tray" class="w-3.5 h-3.5" /> Pull
                        </button>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- ============= Compose tab ============= --%>
        <div :if={@tab == "compose"} class="space-y-4">
          <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 overflow-hidden">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800">
              <h2 class="text-base font-semibold text-gray-900 dark:text-white">Compose Stacks</h2>
              <p class="mt-1 text-xs text-gray-500 dark:text-gray-400">
                Manage Docker Compose projects running on this server.
              </p>
            </div>

            <%= if @compose_stacks == [] do %>
              <div class="py-16 text-center text-gray-400 dark:text-gray-500 text-sm">
                No compose stacks found. Deploy a stack with
                <code class="px-1.5 py-0.5 rounded bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300 text-xs">
                  docker compose up -d
                </code>
                to see it here.
              </div>
            <% else %>
              <div class="divide-y divide-gray-100 dark:divide-gray-800">
                <div
                  :for={stack <- @compose_stacks}
                  class="flex items-center gap-4 px-6 py-4"
                >
                  <div class={[
                    "flex items-center justify-center w-9 h-9 rounded-lg shrink-0",
                    if(compose_running?(stack),
                      do: "bg-green-100 dark:bg-green-900/40 text-green-600 dark:text-green-400",
                      else: "bg-gray-100 dark:bg-gray-800 text-gray-500 dark:text-gray-400"
                    )
                  ]}>
                    <.icon name="hero-square-3-stack-3d" class="w-4 h-4" />
                  </div>

                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium text-gray-900 dark:text-white truncate">
                      {stack.name}
                    </p>
                    <p class="text-xs text-gray-500 dark:text-gray-400">
                      {stack.container_count} container(s) &bull; {stack.status}
                    </p>
                  </div>

                  <div class="flex items-center gap-1.5 shrink-0">
                    <%= if compose_running?(stack) do %>
                      <button
                        id={"compose-restart-#{stack.name}"}
                        phx-click="compose_restart"
                        phx-value-name={stack.name}
                        class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-blue-50 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 hover:bg-blue-100 dark:hover:bg-blue-900/50 text-xs font-medium transition-colors"
                      >
                        <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Restart
                      </button>
                      <button
                        id={"compose-down-#{stack.name}"}
                        phx-click="compose_down"
                        phx-value-name={stack.name}
                        data-confirm={"Stop compose stack \"#{stack.name}\"?"}
                        class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-amber-50 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300 hover:bg-amber-100 dark:hover:bg-amber-900/50 text-xs font-medium transition-colors"
                      >
                        <.icon name="hero-stop" class="w-3.5 h-3.5" /> Down
                      </button>
                    <% else %>
                      <button
                        id={"compose-up-#{stack.name}"}
                        phx-click="compose_up"
                        phx-value-name={stack.name}
                        class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-green-50 dark:bg-green-900/30 text-green-700 dark:text-green-300 hover:bg-green-100 dark:hover:bg-green-900/50 text-xs font-medium transition-colors"
                      >
                        <.icon name="hero-play" class="w-3.5 h-3.5" /> Up
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
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

  defp load_compose_stacks do
    case Docker.list_compose_stacks() do
      {:ok, stacks} -> stacks
      {:error, _} -> []
    end
  end

  defp load_images do
    case Docker.list_images() do
      {:ok, images} -> images
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

  defp format_port_lines(ports) when ports == %{}, do: ""

  defp format_port_lines(ports) when is_map(ports) do
    ports
    |> Enum.flat_map(fn {port_proto, host_ports} ->
      container_port = port_proto |> String.split("/") |> List.first()

      Enum.map(host_ports, fn host_port ->
        "#{host_port}:#{container_port}"
      end)
    end)
    |> Enum.join("\n")
  end

  defp compose_running?(stack) do
    String.contains?(String.downcase(stack.status), "running")
  end

  defp parse_env_pairs(params) do
    parse_env_pairs(params, "env_key_", "env_val_")
  end

  defp parse_env_pairs(params, key_prefix, val_prefix) do
    0..99
    |> Enum.reduce_while([], fn i, acc ->
      key = String.trim(params["#{key_prefix}#{i}"] || "")
      val = params["#{val_prefix}#{i}"] || ""

      cond do
        is_nil(params["#{key_prefix}#{i}"]) -> {:halt, acc}
        key == "" -> {:cont, acc}
        true -> {:cont, [{key, val} | acc]}
      end
    end)
    |> Enum.reverse()
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
