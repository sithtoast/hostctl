defmodule HostctlWeb.DomainLive.Index do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.Domain

  def mount(_params, _session, socket) do
    domains = Hosting.list_domains(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Domains")
     |> assign(:active_tab, :domains)
     |> assign(:domains_empty?, domains == [])
     |> stream(:domains, domains)}
  end

  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:domain, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    domain = %Domain{}

    socket
    |> assign(:domain, domain)
    |> assign(:form, to_form(Hosting.change_domain(domain)))
  end

  def handle_event("delete", %{"id" => id}, socket) do
    domain = Hosting.get_domain!(socket.assigns.current_scope, id)
    {:ok, _} = Hosting.delete_domain(socket.assigns.current_scope, domain)

    domains = Hosting.list_domains(socket.assigns.current_scope)

    {:noreply,
     socket
     |> assign(:domains_empty?, domains == [])
     |> stream_delete(:domains, domain)
     |> put_flash(:info, "Domain deleted.")}
  end

  def handle_event("validate", %{"domain" => params}, socket) do
    form =
      socket.assigns.domain
      |> Hosting.change_domain(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"domain" => params}, socket) do
    case Hosting.create_domain(socket.assigns.current_scope, params) do
      {:ok, domain} ->
        {:noreply,
         socket
         |> assign(:domains_empty?, false)
         |> stream_insert(:domains, domain)
         |> assign(:form, nil)
         |> assign(:domain, nil)
         |> put_flash(:info, "Domain #{domain.name} added successfully.")
         |> push_patch(to: ~p"/domains")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Domains</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">Manage your hosted domains</p>
          </div>
          <.link
            patch={~p"/domains/new"}
            class="inline-flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> Add Domain
          </.link>
        </div>

        <%!-- Add domain modal/form --%>
        <%= if @live_action == :new do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white mb-4">Add New Domain</h2>
            <.form
              for={@form}
              id="domain-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Domain Name"
                  placeholder="example.com"
                />
                <.input
                  field={@form[:php_version]}
                  type="select"
                  label="PHP Version"
                  options={[
                    {"PHP 8.4", "8.4"},
                    {"PHP 8.3", "8.3"},
                    {"PHP 8.2", "8.2"},
                    {"PHP 8.1", "8.1"},
                    {"PHP 8.0", "8.0"},
                    {"PHP 7.4", "7.4"}
                  ]}
                />
              </div>
              <.input
                field={@form[:document_root]}
                type="text"
                label="Document Root"
                placeholder="/var/www/example.com/public"
              />
              <div class="flex items-center gap-3 pt-2">
                <button
                  type="submit"
                  class="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
                >
                  Add Domain
                </button>
                <.link
                  patch={~p"/domains"}
                  class="px-4 py-2 text-sm font-medium text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-white"
                >
                  Cancel
                </.link>
              </div>
            </.form>
          </div>
        <% end %>

        <%!-- Domain list --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
          <div id="domains" phx-update="stream">
            <div class={[
              "flex flex-col items-center justify-center py-16 gap-3",
              if(@domains_empty?, do: "block", else: "hidden")
            ]}>
              <div class="flex items-center justify-center w-12 h-12 rounded-xl bg-gray-100 dark:bg-gray-800">
                <.icon name="hero-globe-alt" class="w-6 h-6 text-gray-400" />
              </div>
              <p class="text-sm font-medium text-gray-900 dark:text-white">No domains yet</p>
              <p class="text-sm text-gray-500 dark:text-gray-400">
                Get started by adding your first domain.
              </p>
              <.link
                patch={~p"/domains/new"}
                class="mt-2 inline-flex items-center gap-2 px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> Add Domain
              </.link>
            </div>

            <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
              <thead>
                <tr class="bg-gray-50 dark:bg-gray-800/50">
                  <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    Domain
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    PHP
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    SSL
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="relative px-6 py-3"><span class="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100 dark:divide-gray-800">
                <tr
                  :for={{id, domain} <- @streams.domains}
                  id={id}
                  class="hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
                >
                  <td class="px-6 py-4">
                    <div class="flex items-center gap-3">
                      <div class="flex items-center justify-center w-8 h-8 rounded-lg bg-indigo-100 dark:bg-indigo-900/30 shrink-0">
                        <.icon
                          name="hero-globe-alt"
                          class="w-4 h-4 text-indigo-600 dark:text-indigo-400"
                        />
                      </div>
                      <div>
                        <p class="text-sm font-medium text-gray-900 dark:text-white">{domain.name}</p>
                        <p class="text-xs text-gray-500 dark:text-gray-400">
                          {domain.document_root || "/"}
                        </p>
                      </div>
                    </div>
                  </td>
                  <td class="px-6 py-4">
                    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400">
                      PHP {domain.php_version}
                    </span>
                  </td>
                  <td class="px-6 py-4">
                    <%= if domain.ssl_enabled do %>
                      <span class="inline-flex items-center gap-1 text-xs font-medium text-green-600 dark:text-green-400">
                        <.icon name="hero-lock-closed" class="w-3.5 h-3.5" /> Active
                      </span>
                    <% else %>
                      <span class="text-xs text-gray-400">None</span>
                    <% end %>
                  </td>
                  <td class="px-6 py-4">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium",
                      cond do
                        domain.status == "active" ->
                          "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400"

                        domain.status == "suspended" ->
                          "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"

                        true ->
                          "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400"
                      end
                    ]}>
                      {domain.status}
                    </span>
                  </td>
                  <td class="px-6 py-4 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <.link
                        navigate={~p"/domains/#{domain.id}"}
                        class="text-xs font-medium text-indigo-600 dark:text-indigo-400 hover:text-indigo-500"
                      >
                        Manage
                      </.link>
                      <button
                        phx-click="delete"
                        phx-value-id={domain.id}
                        data-confirm={"Are you sure you want to delete #{domain.name}? This cannot be undone."}
                        class="text-xs font-medium text-red-500 hover:text-red-600 dark:text-red-400 dark:hover:text-red-300"
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
      </div>
    </Layouts.app>
    """
  end
end
