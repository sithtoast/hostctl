defmodule HostctlWeb.DnsLive.Index do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.DnsRecord

  def mount(%{"domain_id" => domain_id}, _session, socket) do
    domain = Hosting.get_domain!(socket.assigns.current_scope, domain_id)
    zone = Hosting.get_dns_zone_with_records!(domain)

    {:ok,
     socket
     |> assign(:page_title, "DNS – #{domain.name}")
     |> assign(:active_tab, :domains)
     |> assign(:domain, domain)
     |> assign(:zone, zone)
     |> assign(:editing_record, nil)
     |> assign_new_form()
     |> stream(:dns_records, zone.dns_records)}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("validate", %{"dns_record" => params}, socket) do
    form =
      %DnsRecord{}
      |> Hosting.change_dns_record(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"dns_record" => params}, socket) do
    case Hosting.create_dns_record(socket.assigns.zone, params) do
      {:ok, record} ->
        {:noreply,
         socket
         |> stream_insert(:dns_records, record)
         |> assign_new_form()
         |> put_flash(:info, "DNS record added.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    records = Hosting.get_dns_zone_with_records!(socket.assigns.domain).dns_records
    record = Enum.find(records, &(to_string(&1.id) == id))

    if record do
      {:ok, _} = Hosting.delete_dns_record(record)
      {:noreply, stream_delete(socket, :dns_records, record)}
    else
      {:noreply, socket}
    end
  end

  defp assign_new_form(socket) do
    assign(socket, :form, to_form(Hosting.change_dns_record(%DnsRecord{})))
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={@active_tab}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center gap-4">
          <.link
            navigate={~p"/domains/#{@domain.id}"}
            class="text-gray-400 hover:text-gray-600 dark:hover:text-gray-200"
          >
            <.icon name="hero-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">DNS Manager</h1>
            <p class="mt-0.5 text-sm text-gray-500 dark:text-gray-400">{@domain.name}</p>
          </div>
        </div>

        <%!-- Add record form --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-6">
          <h2 class="text-base font-semibold text-gray-900 dark:text-white mb-4">Add DNS Record</h2>
          <.form
            for={@form}
            id="dns-record-form"
            phx-change="validate"
            phx-submit="save"
            class="grid grid-cols-1 gap-4 sm:grid-cols-5"
          >
            <.input
              field={@form[:type]}
              type="select"
              label="Type"
              options={DnsRecord.valid_types()}
            />
            <.input field={@form[:name]} type="text" label="Name" placeholder="@ or subdomain" />
            <div class="sm:col-span-2">
              <.input
                field={@form[:value]}
                type="text"
                label="Value"
                placeholder="IP address or hostname"
              />
            </div>
            <.input field={@form[:ttl]} type="number" label="TTL" placeholder="3600" />
            <div class="sm:col-span-4">
              <.input
                field={@form[:priority]}
                type="number"
                label="Priority (MX/SRV only)"
                placeholder="10"
              />
            </div>
            <div class="flex items-end">
              <button
                type="submit"
                class="w-full px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg transition-colors"
              >
                Add Record
              </button>
            </div>
          </.form>
        </div>

        <%!-- Records table --%>
        <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
          <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800 flex items-center justify-between">
            <h2 class="text-base font-semibold text-gray-900 dark:text-white">DNS Records</h2>
            <span class="text-sm text-gray-500 dark:text-gray-400">TTL: {@zone.ttl}s</span>
          </div>
          <div id="dns-records" phx-update="stream">
            <div class="hidden only:flex items-center justify-center py-12 text-sm text-gray-400">
              No DNS records yet. Add your first record above.
            </div>
            <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
              <thead>
                <tr class="bg-gray-50 dark:bg-gray-800/50">
                  <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider w-16">
                    Type
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                    Name
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                    Value
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider w-20">
                    TTL
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider w-20">
                    Priority
                  </th>
                  <th class="relative px-4 py-3 w-16"><span class="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100 dark:divide-gray-800">
                <tr
                  :for={{id, record} <- @streams.dns_records}
                  id={id}
                  class="hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
                >
                  <td class="px-4 py-3">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-bold font-mono",
                      cond do
                        record.type in ~w(A AAAA) ->
                          "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400"

                        record.type == "MX" ->
                          "bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-400"

                        record.type == "CNAME" ->
                          "bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400"

                        record.type == "TXT" ->
                          "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400"

                        true ->
                          "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300"
                      end
                    ]}>
                      {record.type}
                    </span>
                  </td>
                  <td class="px-4 py-3 font-mono text-sm text-gray-900 dark:text-white">
                    {record.name}
                  </td>
                  <td class="px-4 py-3 font-mono text-sm text-gray-600 dark:text-gray-300 max-w-xs truncate">
                    {record.value}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-500">{record.ttl}</td>
                  <td class="px-4 py-3 text-sm text-gray-500">{record.priority || "—"}</td>
                  <td class="px-4 py-3 text-right">
                    <button
                      phx-click="delete"
                      phx-value-id={record.id}
                      data-confirm="Delete this DNS record?"
                      class="text-xs text-red-500 hover:text-red-600"
                    >
                      Delete
                    </button>
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
