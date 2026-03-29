defmodule HostctlWeb.DatabaseLive.Index do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.Database
  alias Hostctl.Hosting.DbUser

  def mount(_params, _session, socket) do
    domains = Hosting.list_domains(socket.assigns.current_scope)
    all_databases = Enum.flat_map(domains, &Hosting.list_databases/1)

    {:ok,
     socket
     |> assign(:page_title, "Databases")
     |> assign(:active_tab, :databases)
     |> assign(:domains, domains)
     |> assign(:selected_domain_id, nil)
     |> assign(:expanded_db, nil)
     |> assign(:db_users, [])
     |> assign(:db_user_form, nil)
     |> assign(:dbs_empty?, all_databases == [])
     |> assign_db_form()
     |> stream(:databases, all_databases)}
  end

  def handle_event("select_domain", %{"domain_id" => domain_id}, socket) do
    domain_id = if domain_id == "", do: nil, else: String.to_integer(domain_id)

    databases =
      if domain_id do
        domain = Hosting.get_domain!(socket.assigns.current_scope, domain_id)
        Hosting.list_databases(domain)
      else
        Enum.flat_map(socket.assigns.domains, &Hosting.list_databases/1)
      end

    {:noreply,
     socket
     |> assign(:selected_domain_id, domain_id)
     |> assign(:dbs_empty?, databases == [])
     |> stream(:databases, databases, reset: true)}
  end

  def handle_event("validate_db", %{"database" => params}, socket) do
    form =
      %Database{}
      |> Hosting.change_database(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :db_form, form)}
  end

  def handle_event("save_db", %{"database" => params}, socket) do
    domain_id = socket.assigns.selected_domain_id || get_first_domain_id(socket)
    domain = Hosting.get_domain!(socket.assigns.current_scope, domain_id)

    case Hosting.create_database(domain, params) do
      {:ok, database} ->
        {:noreply,
         socket
         |> assign(:dbs_empty?, false)
         |> stream_insert(:databases, database)
         |> assign_db_form()
         |> put_flash(:info, "Database #{database.name} created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :db_form, to_form(changeset))}
    end
  end

  def handle_event("delete_db", %{"id" => id}, socket) do
    databases = Enum.flat_map(socket.assigns.domains, &Hosting.list_databases/1)
    database = Enum.find(databases, &(to_string(&1.id) == id))

    if database do
      {:ok, _} = Hosting.delete_database(database)
      all_dbs = Enum.flat_map(socket.assigns.domains, &Hosting.list_databases/1)

      {:noreply,
       socket
       |> assign(:dbs_empty?, all_dbs == [])
       |> stream_delete(:databases, database)
       |> put_flash(:info, "Database deleted.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_db_users", %{"id" => id}, socket) do
    db_id = String.to_integer(id)
    prev_db = socket.assigns.expanded_db

    if prev_db && prev_db.id == db_id do
      {:noreply,
       socket
       |> assign(:expanded_db, nil)
       |> assign(:db_users, [])
       |> assign(:db_user_form, nil)
       |> stream_insert(:databases, prev_db)}
    else
      databases = Enum.flat_map(socket.assigns.domains, &Hosting.list_databases/1)

      case Enum.find(databases, &(&1.id == db_id)) do
        nil ->
          {:noreply, socket}

        db ->
          db_users = Hosting.list_db_users(db)

          socket =
            socket
            |> assign(:expanded_db, db)
            |> assign(:db_users, db_users)
            |> assign_db_user_form()
            |> stream_insert(:databases, db)

          socket =
            if prev_db,
              do: stream_insert(socket, :databases, prev_db),
              else: socket

          {:noreply, socket}
      end
    end
  end

  def handle_event("validate_db_user", %{"db_user" => params}, socket) do
    form =
      %DbUser{}
      |> Hosting.change_db_user(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :db_user_form, form)}
  end

  def handle_event("save_db_user", %{"db_user" => params}, socket) do
    database = socket.assigns.expanded_db

    case Hosting.create_db_user(database, params) do
      {:ok, db_user} ->
        db_users = Hosting.list_db_users(database)

        {:noreply,
         socket
         |> assign(:db_users, db_users)
         |> assign_db_user_form()
         |> put_flash(:info, "User #{db_user.username} created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :db_user_form, to_form(changeset))}
    end
  end

  def handle_event("delete_db_user", %{"id" => id}, socket) do
    database = socket.assigns.expanded_db
    db_user = Hosting.get_db_user!(database, String.to_integer(id))
    {:ok, _} = Hosting.delete_db_user(db_user, database)
    db_users = Hosting.list_db_users(database)

    {:noreply,
     socket
     |> assign(:db_users, db_users)
     |> put_flash(:info, "User deleted.")}
  end

  defp assign_db_form(socket) do
    assign(socket, :db_form, to_form(Hosting.change_database(%Database{})))
  end

  defp assign_db_user_form(socket) do
    assign(socket, :db_user_form, to_form(Hosting.change_db_user(%DbUser{})))
  end

  defp get_first_domain_id(socket) do
    case socket.assigns.domains do
      [domain | _] -> domain.id
      [] -> nil
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Databases</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Manage your MySQL and PostgreSQL databases
            </p>
          </div>
        </div>

        <%= if @domains == [] do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-12 text-center">
            <.icon
              name="hero-circle-stack"
              class="w-10 h-10 text-gray-300 dark:text-gray-600 mx-auto mb-3"
            />
            <p class="text-sm font-medium text-gray-900 dark:text-white">No domains yet</p>
            <p class="text-sm text-gray-500 dark:text-gray-400 mb-4">
              Add a domain first to create databases.
            </p>
            <.link
              navigate={~p"/domains/new"}
              class="inline-flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> Add Domain
            </.link>
          </div>
        <% else %>
          <%!-- Create database form --%>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white mb-4">
              Create Database
            </h2>
            <.form
              for={@db_form}
              id="database-form"
              phx-change="validate_db"
              phx-submit="save_db"
              class="space-y-4"
            >
              <%!-- Base errors (e.g. MySQL connection failure) --%>
              <%= if error = @db_form.errors[:base] do %>
                <div class="rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 p-3 text-sm text-red-700 dark:text-red-400">
                  {elem(error, 0)}
                </div>
              <% end %>
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-4">
                <div class="sm:col-span-2">
                  <.input
                    field={@db_form[:name]}
                    type="text"
                    label="Database Name"
                    placeholder="myapp_production"
                  />
                </div>
                <.input
                  field={@db_form[:db_type]}
                  type="select"
                  label="Type"
                  options={[{"PostgreSQL", "postgresql"}, {"MySQL", "mysql"}]}
                />
                <div>
                  <label class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                    Domain
                  </label>
                  <select
                    name="domain_id"
                    phx-change="select_domain"
                    class="block w-full rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-3 py-2 text-sm text-gray-900 dark:text-white focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
                  >
                    <option
                      :for={domain <- @domains}
                      value={domain.id}
                      selected={@selected_domain_id == domain.id}
                    >
                      {domain.name}
                    </option>
                  </select>
                </div>
                <div class="sm:col-span-4 flex justify-end">
                  <button
                    type="submit"
                    class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                  >
                    Create Database
                  </button>
                </div>
              </div>
            </.form>
          </div>

          <%!-- Filter by domain --%>
          <div class="flex items-center gap-3 flex-wrap">
            <span class="text-sm text-gray-600 dark:text-gray-400">Filter:</span>
            <button
              phx-click="select_domain"
              phx-value-domain_id=""
              class={[
                "px-3 py-1 rounded-full text-xs font-medium transition-colors",
                if(@selected_domain_id == nil,
                  do: "bg-indigo-600 text-white",
                  else:
                    "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700"
                )
              ]}
            >
              All
            </button>
            <button
              :for={domain <- @domains}
              phx-click="select_domain"
              phx-value-domain_id={domain.id}
              class={[
                "px-3 py-1 rounded-full text-xs font-medium transition-colors",
                if(@selected_domain_id == domain.id,
                  do: "bg-indigo-600 text-white",
                  else:
                    "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700"
                )
              ]}
            >
              {domain.name}
            </button>
          </div>

          <%!-- Databases list --%>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
            <div id="databases" phx-update="stream">
              <div class={[
                "flex flex-col items-center justify-center py-16 gap-3",
                if(@dbs_empty?, do: "block", else: "hidden")
              ]}>
                <.icon
                  name="hero-circle-stack"
                  class="w-10 h-10 text-gray-300 dark:text-gray-600 mx-auto"
                />
                <p class="text-sm text-gray-400 mt-2">No databases yet.</p>
              </div>
              <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
                <thead>
                  <tr class="bg-gray-50 dark:bg-gray-800/50">
                    <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                      Name
                    </th>
                    <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                      Type
                    </th>
                    <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                      Status
                    </th>
                    <th class="relative px-6 py-3"><span class="sr-only">Actions</span></th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100 dark:divide-gray-800">
                  <tr
                    :for={{id, db} <- @streams.databases}
                    id={id}
                    class="hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
                  >
                    <td class="px-6 py-4">
                      <div class="flex items-center gap-3">
                        <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-purple-100 dark:bg-purple-900/30 shrink-0">
                          <.icon
                            name="hero-circle-stack"
                            class="w-4 h-4 text-purple-600 dark:text-purple-400"
                          />
                        </div>
                        <p class="font-mono text-sm font-medium text-gray-900 dark:text-white">
                          {db.name}
                        </p>
                      </div>
                    </td>
                    <td class="px-6 py-4">
                      <span class={[
                        "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                        if(db.db_type == "postgresql",
                          do: "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400",
                          else:
                            "bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400"
                        )
                      ]}>
                        {if db.db_type == "postgresql", do: "PostgreSQL", else: "MySQL"}
                      </span>
                    </td>
                    <td class="px-6 py-4">
                      <span class={[
                        "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
                        if(db.status == "active",
                          do: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400",
                          else: "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"
                        )
                      ]}>
                        {db.status}
                      </span>
                    </td>
                    <td class="px-6 py-4 text-right">
                      <div class="flex items-center justify-end gap-4">
                        <button
                          phx-click="toggle_db_users"
                          phx-value-id={db.id}
                          class={[
                            "text-xs font-medium transition-colors",
                            if(@expanded_db && @expanded_db.id == db.id,
                              do: "text-indigo-600 dark:text-indigo-400",
                              else:
                                "text-gray-500 hover:text-indigo-600 dark:text-gray-400 dark:hover:text-indigo-400"
                            )
                          ]}
                        >
                          Users
                        </button>
                        <button
                          phx-click="delete_db"
                          phx-value-id={db.id}
                          data-confirm={"Delete database #{db.name}? This cannot be undone."}
                          class="text-xs font-medium text-red-500 hover:text-red-600"
                        >
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Database Users Panel --%>
          <%= if @expanded_db do %>
            <div
              id="db-users-panel"
              class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 overflow-hidden"
            >
              <div class="flex items-center justify-between px-6 py-4 border-b border-gray-100 dark:border-gray-800">
                <div class="flex items-center gap-3">
                  <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-indigo-100 dark:bg-indigo-900/30 shrink-0">
                    <.icon name="hero-users" class="w-4 h-4 text-indigo-600 dark:text-indigo-400" />
                  </div>
                  <div>
                    <h2 class="text-sm font-semibold text-gray-900 dark:text-white">
                      Users — <span class="font-mono">{@expanded_db.name}</span>
                    </h2>
                    <p class="text-xs text-gray-500 dark:text-gray-400">
                      {if @expanded_db.db_type == "mysql",
                        do: "MySQL users are provisioned on the server automatically.",
                        else: "Credential records for this PostgreSQL database."}
                    </p>
                  </div>
                </div>
                <button
                  phx-click="toggle_db_users"
                  phx-value-id={@expanded_db.id}
                  class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-200 transition-colors rounded-lg p-1"
                >
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              </div>

              <%!-- Existing users list --%>
              <div class="px-6 py-4">
                <%= if @db_users == [] do %>
                  <p class="text-sm text-gray-400 dark:text-gray-500 text-center py-6">
                    No users yet. Add one below.
                  </p>
                <% else %>
                  <table class="min-w-full">
                    <thead>
                      <tr>
                        <th class="pb-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                          Username
                        </th>
                        <th class="pb-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                          Created
                        </th>
                        <th class="pb-3 relative"><span class="sr-only">Actions</span></th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-gray-100 dark:divide-gray-800">
                      <tr :for={user <- @db_users} id={"db-user-#{user.id}"}>
                        <td class="py-3">
                          <div class="flex items-center gap-2">
                            <.icon name="hero-user" class="w-4 h-4 text-gray-400 shrink-0" />
                            <span class="font-mono text-sm text-gray-900 dark:text-white">
                              {user.username}
                            </span>
                          </div>
                        </td>
                        <td class="py-3 text-sm text-gray-500 dark:text-gray-400">
                          {Calendar.strftime(user.inserted_at, "%b %d, %Y")}
                        </td>
                        <td class="py-3 text-right">
                          <button
                            phx-click="delete_db_user"
                            phx-value-id={user.id}
                            data-confirm={"Delete user #{user.username}? This cannot be undone."}
                            class="text-xs font-medium text-red-500 hover:text-red-600 transition-colors"
                          >
                            Delete
                          </button>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                <% end %>
              </div>

              <%!-- Add user form --%>
              <div class="px-6 py-4 border-t border-gray-100 dark:border-gray-800 bg-gray-50/50 dark:bg-gray-800/20">
                <h3 class="text-xs font-semibold text-gray-600 dark:text-gray-400 uppercase tracking-wider mb-3">
                  Add User
                </h3>
                <.form
                  for={@db_user_form}
                  id="db-user-form"
                  phx-change="validate_db_user"
                  phx-submit="save_db_user"
                  class="space-y-3"
                >
                  <%!-- Base (server-side) errors, e.g. MySQL connection failures --%>
                  <%= if error = @db_user_form.errors[:base] do %>
                    <div class="rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 p-3 text-sm text-red-700 dark:text-red-400">
                      {elem(error, 0)}
                    </div>
                  <% end %>
                  <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
                    <.input
                      field={@db_user_form[:username]}
                      type="text"
                      label="Username"
                      placeholder="wp_user"
                    />
                    <.input
                      field={@db_user_form[:password]}
                      type="password"
                      label="Password"
                      placeholder="Min. 8 characters"
                    />
                    <div class="flex items-end">
                      <button
                        type="submit"
                        class="w-full px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                      >
                        Add User
                      </button>
                    </div>
                  </div>
                </.form>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
