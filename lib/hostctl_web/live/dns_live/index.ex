defmodule HostctlWeb.DnsLive.Index do
  use HostctlWeb, :live_view

  alias Hostctl.Hosting
  alias Hostctl.Hosting.DnsRecord
  alias Hostctl.Settings

  def mount(%{"domain_id" => domain_id}, _session, socket) do
    scope = socket.assigns.current_scope
    is_admin = scope.user.role == "admin"

    domain =
      if is_admin do
        Hosting.get_domain_for_admin!(domain_id)
      else
        Hosting.get_domain!(scope, domain_id)
      end

    zone =
      case Hosting.get_dns_zone_for_domain(domain) do
        nil ->
          {:ok, zone} =
            %Hostctl.Hosting.DnsZone{domain_id: domain.id}
            |> Hostctl.Hosting.DnsZone.changeset(%{})
            |> Hostctl.Repo.insert()

          %{zone | dns_records: []}

        _exists ->
          Hosting.get_dns_zone_with_records!(domain)
      end

    dns_setting = Settings.get_dns_provider_setting()

    {:ok,
     socket
     |> assign(:page_title, "DNS – #{domain.name}")
     |> assign(:active_tab, :domains)
     |> assign(:domain, domain)
     |> assign(:zone, zone)
     |> assign(:dns_setting, dns_setting)
     |> assign(:cloudflare_records, [])
     |> assign(:cloudflare_records_loaded, false)
     |> assign(:editing_record_id, nil)
     |> assign(:edit_form, nil)
     |> assign_new_form()
     |> stream(:dns_records, zone.dns_records)}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # --------------------------------------------------------------------------
  # Add record
  # --------------------------------------------------------------------------

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
        zone = Hosting.get_dns_zone_with_records!(socket.assigns.domain)

        {:noreply,
         socket
         |> assign(:zone, zone)
         |> stream_insert(:dns_records, record)
         |> assign_new_form()
         |> put_flash(:info, "DNS record added.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # --------------------------------------------------------------------------
  # Inline edit
  # --------------------------------------------------------------------------

  def handle_event("edit", %{"id" => id}, socket) do
    zone = socket.assigns.zone
    record = Enum.find(zone.dns_records, &(to_string(&1.id) == id))

    if record do
      edit_form = to_form(Hosting.change_dns_record(record), as: :dns_record)

      {:noreply,
       socket
       |> assign(:editing_record_id, record.id)
       |> assign(:edit_form, edit_form)
       |> stream_insert(:dns_records, record)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply, socket |> assign(:editing_record_id, nil) |> assign(:edit_form, nil)}
  end

  def handle_event("validate_edit", %{"dns_record" => params}, socket) do
    zone = socket.assigns.zone
    record = Enum.find(zone.dns_records, &(&1.id == socket.assigns.editing_record_id))
    form = to_form(Hosting.change_dns_record(record, params), as: :dns_record, action: :validate)
    {:noreply, assign(socket, :edit_form, form)}
  end

  def handle_event("save_edit", %{"dns_record" => params}, socket) do
    zone = socket.assigns.zone
    record = Enum.find(zone.dns_records, &(&1.id == socket.assigns.editing_record_id))

    case Hosting.update_dns_record(record, params) do
      {:ok, updated} ->
        zone = Hosting.get_dns_zone_with_records!(socket.assigns.domain)

        {:noreply,
         socket
         |> assign(:zone, zone)
         |> assign(:editing_record_id, nil)
         |> assign(:edit_form, nil)
         |> stream_insert(:dns_records, updated)
         |> put_flash(:info, "DNS record updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset, as: :dns_record))}
    end
  end

  # --------------------------------------------------------------------------
  # Delete
  # --------------------------------------------------------------------------

  def handle_event("delete", %{"id" => id}, socket) do
    zone = socket.assigns.zone
    record = Enum.find(zone.dns_records, &(to_string(&1.id) == id))

    if record do
      {:ok, _} = Hosting.delete_dns_record(record)
      zone = Hosting.get_dns_zone_with_records!(socket.assigns.domain)

      {:noreply,
       socket
       |> assign(:zone, zone)
       |> stream_delete(:dns_records, record)}
    else
      {:noreply, socket}
    end
  end

  # --------------------------------------------------------------------------
  # Cloudflare zone linking
  # --------------------------------------------------------------------------

  def handle_event("link_cloudflare_zone", _, socket) do
    case Hosting.link_zone_to_cloudflare(socket.assigns.zone) do
      {:ok, updated_zone} ->
        zone = %{updated_zone | dns_records: socket.assigns.zone.dns_records}

        {:noreply,
         socket
         |> assign(:zone, zone)
         |> put_flash(
           :info,
           "Zone linked to Cloudflare (ID: #{updated_zone.cloudflare_zone_id})."
         )}

      {:error, :zone_not_found} ->
        {:noreply, put_flash(socket, :error, "Domain not found in your Cloudflare account.")}

      {:error, :cloudflare_not_configured} ->
        {:noreply, put_flash(socket, :error, "Cloudflare is not configured in Panel Settings.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cloudflare error: #{reason}")}
    end
  end

  def handle_event("unlink_cloudflare_zone", _, socket) do
    case Hosting.update_dns_zone(socket.assigns.zone, %{cloudflare_zone_id: nil}) do
      {:ok, updated_zone} ->
        zone = %{updated_zone | dns_records: socket.assigns.zone.dns_records}

        {:noreply,
         socket
         |> assign(:zone, zone)
         |> put_flash(:info, "Cloudflare zone unlinked.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unlink zone.")}
    end
  end

  def handle_event("sync_to_cloudflare", _, socket) do
    case Hosting.sync_zone_to_cloudflare(socket.assigns.zone) do
      {:ok, %{synced: count, failed: 0}} ->
        zone = Hosting.get_dns_zone_with_records!(socket.assigns.domain)

        {:noreply,
         socket
         |> assign(:zone, zone)
         |> stream(:dns_records, zone.dns_records, reset: true)
         |> put_flash(:info, "Synced #{count} record(s) to Cloudflare.")}

      {:ok, %{synced: ok, failed: failed}} ->
        zone = Hosting.get_dns_zone_with_records!(socket.assigns.domain)

        {:noreply,
         socket
         |> assign(:zone, zone)
         |> stream(:dns_records, zone.dns_records, reset: true)
         |> put_flash(
           :error,
           "Synced #{ok} record(s) to Cloudflare. #{failed} failed — check logs."
         )}

      {:error, :not_linked} ->
        {:noreply, put_flash(socket, :error, "Zone is not linked to Cloudflare.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Cloudflare sync failed — check settings.")}
    end
  end

  def handle_event("refresh_cloudflare_records", _, socket) do
    case Hosting.list_cloudflare_zone_records(socket.assigns.zone) do
      {:ok, records} ->
        {:noreply,
         socket
         |> assign(:cloudflare_records, records)
         |> assign(:cloudflare_records_loaded, true)
         |> put_flash(:info, "Loaded #{length(records)} Cloudflare record(s).")}

      {:error, :not_linked} ->
        {:noreply, put_flash(socket, :error, "Zone is not linked to Cloudflare.")}

      {:error, :cloudflare_not_configured} ->
        {:noreply, put_flash(socket, :error, "Cloudflare is not configured in Panel Settings.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cloudflare refresh failed: #{inspect(reason)}")}
    end
  end

  def handle_event("import_cloudflare_records", _, socket) do
    with {:ok, records} <- current_or_remote_cloudflare_records(socket),
         {:ok, summary} <- Hosting.import_cloudflare_zone_records(socket.assigns.zone, records) do
      zone = Hosting.get_dns_zone_with_records!(socket.assigns.domain)

      {:noreply,
       socket
       |> assign(:zone, zone)
       |> assign(:cloudflare_records, records)
       |> assign(:cloudflare_records_loaded, true)
       |> stream(:dns_records, zone.dns_records, reset: true)
       |> put_flash(
         :info,
         "Imported #{summary.imported} Cloudflare record(s), updated #{summary.updated}, skipped #{summary.skipped}."
       )}
    else
      {:error, :not_linked} ->
        {:noreply, put_flash(socket, :error, "Zone is not linked to Cloudflare.")}

      {:error, :cloudflare_not_configured} ->
        {:noreply, put_flash(socket, :error, "Cloudflare is not configured in Panel Settings.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         put_flash(socket, :error, "Cloudflare import failed: #{inspect(changeset.errors)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cloudflare import failed: #{inspect(reason)}")}
    end
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp assign_new_form(socket) do
    assign(socket, :form, to_form(Hosting.change_dns_record(%DnsRecord{})))
  end

  defp current_or_remote_cloudflare_records(socket) do
    if socket.assigns.cloudflare_records_loaded do
      {:ok, socket.assigns.cloudflare_records}
    else
      Hosting.list_cloudflare_zone_records(socket.assigns.zone)
    end
  end

  defp cloudflare_enabled?(dns_setting) do
    dns_setting.provider == "cloudflare" &&
      is_binary(dns_setting.cloudflare_api_token) &&
      dns_setting.cloudflare_api_token != ""
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
          <div class="flex-1">
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">DNS Manager</h1>
            <p class="mt-0.5 text-sm text-gray-500 dark:text-gray-400">{@domain.name}</p>
          </div>
          <%!-- Provider badge --%>
          <%= if cloudflare_enabled?(@dns_setting) do %>
            <div class="flex items-center gap-2">
              <%= if @zone.cloudflare_zone_id do %>
                <span class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-orange-100 dark:bg-orange-900/20 text-orange-700 dark:text-orange-400 text-xs font-semibold">
                  <.icon name="hero-cloud" class="w-3.5 h-3.5" /> Cloudflare Active
                </span>
                <button
                  id="sync-cf-btn"
                  phx-click="sync_to_cloudflare"
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-orange-100 hover:bg-orange-200 dark:bg-orange-900/20 dark:hover:bg-orange-900/30 text-orange-700 dark:text-orange-400 text-xs font-semibold transition-colors"
                >
                  <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Sync
                </button>
                <button
                  id="unlink-cf-btn"
                  phx-click="unlink_cloudflare_zone"
                  class="text-xs text-gray-400 hover:text-red-500 transition-colors"
                >
                  Unlink
                </button>
              <% else %>
                <span class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-gray-100 dark:bg-gray-800 text-gray-500 dark:text-gray-400 text-xs font-medium">
                  <.icon name="hero-cloud" class="w-3.5 h-3.5" /> Cloudflare
                </span>
                <button
                  id="link-cf-btn"
                  phx-click="link_cloudflare_zone"
                  class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-orange-500 hover:bg-orange-600 text-white text-xs font-semibold transition-colors"
                >
                  <.icon name="hero-link" class="w-3.5 h-3.5" /> Link Zone
                </button>
              <% end %>
            </div>
          <% else %>
            <span class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-gray-100 dark:bg-gray-800 text-gray-500 dark:text-gray-400 text-xs font-medium">
              <.icon name="hero-server" class="w-3.5 h-3.5" /> Local DNS
            </span>
          <% end %>
        </div>

        <%!-- Cloudflare info banner (zone not yet linked) --%>
        <%= if cloudflare_enabled?(@dns_setting) && is_nil(@zone.cloudflare_zone_id) do %>
          <div class="flex items-start gap-3 px-4 py-3 rounded-xl bg-orange-50 dark:bg-orange-900/10 border border-orange-200 dark:border-orange-800">
            <.icon name="hero-information-circle" class="w-5 h-5 text-orange-500 shrink-0 mt-0.5" />
            <div class="text-sm text-orange-700 dark:text-orange-300">
              <span class="font-semibold">Cloudflare is configured</span>
              but this zone isn't linked yet. Click <span class="font-semibold">Link Zone</span>
              to auto-discover the Cloudflare zone for <span class="font-mono">{@domain.name}</span>. New records will sync automatically once linked.
            </div>
          </div>
        <% end %>

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
                <%= if cloudflare_enabled?(@dns_setting) && @zone.cloudflare_zone_id do %>
                  <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider w-24">
                    Sync
                  </th>
                <% end %>
                <th class="relative px-4 py-3 w-24"><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody
              id="dns-records"
              phx-update="stream"
              class="divide-y divide-gray-100 dark:divide-gray-800"
            >
              <tr class="hidden only:table-row">
                <td colspan="7" class="px-4 py-12 text-center text-sm text-gray-400">
                  No DNS records yet. Add your first record above.
                </td>
              </tr>
                <tr
                  :for={{dom_id, record} <- @streams.dns_records}
                  id={dom_id}
                  class="hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
                >
                  <%= if @editing_record_id == record.id do %>
                    <%!-- Inline edit row --%>
                    <td colspan="7" class="px-4 py-3">
                      <.form
                        for={@edit_form}
                        id={"edit-record-form-#{record.id}"}
                        phx-change="validate_edit"
                        phx-submit="save_edit"
                        class="grid grid-cols-2 gap-3 sm:grid-cols-6"
                      >
                        <.input
                          field={@edit_form[:type]}
                          type="select"
                          label="Type"
                          options={DnsRecord.valid_types()}
                        />
                        <.input field={@edit_form[:name]} type="text" label="Name" />
                        <div class="sm:col-span-2">
                          <.input field={@edit_form[:value]} type="text" label="Value" />
                        </div>
                        <.input field={@edit_form[:ttl]} type="number" label="TTL" />
                        <.input field={@edit_form[:priority]} type="number" label="Priority" />
                        <div class="col-span-2 sm:col-span-6 flex items-center gap-2 pt-1">
                          <button
                            type="submit"
                            class="px-3 py-1.5 bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium rounded-lg transition-colors"
                          >
                            Save
                          </button>
                          <button
                            type="button"
                            phx-click="cancel_edit"
                            class="px-3 py-1.5 text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 text-xs font-medium transition-colors"
                          >
                            Cancel
                          </button>
                        </div>
                      </.form>
                    </td>
                  <% else %>
                    <%!-- Normal display row --%>
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
                    <%= if cloudflare_enabled?(@dns_setting) && @zone.cloudflare_zone_id do %>
                      <td class="px-4 py-3">
                        <%= if record.cloudflare_record_id do %>
                          <span
                            title={"CF: #{record.cloudflare_record_id}"}
                            class="inline-flex items-center gap-1 text-xs text-orange-600 dark:text-orange-400 font-medium"
                          >
                            <.icon name="hero-check-circle" class="w-3.5 h-3.5" /> Synced
                          </span>
                        <% else %>
                          <span class="inline-flex items-center gap-1 text-xs text-gray-400 dark:text-gray-500">
                            <.icon name="hero-minus-circle" class="w-3.5 h-3.5" /> Local
                          </span>
                        <% end %>
                      </td>
                    <% end %>
                    <td class="px-4 py-3 text-right">
                      <div class="flex items-center justify-end gap-3">
                        <button
                          phx-click="edit"
                          phx-value-id={record.id}
                          class="text-xs text-indigo-500 hover:text-indigo-600 font-medium"
                        >
                          Edit
                        </button>
                        <button
                          phx-click="delete"
                          phx-value-id={record.id}
                          data-confirm="Delete this DNS record?"
                          class="text-xs text-red-500 hover:text-red-600"
                        >
                          Delete
                        </button>
                      </div>
                    </td>
                  <% end %>
                </tr>
              </tbody>
            </table>
        </div>

        <%!-- Cloudflare footer (zone is linked) --%>
        <%= if cloudflare_enabled?(@dns_setting) && @zone.cloudflare_zone_id do %>
          <div class="flex items-center justify-between gap-3 px-4 py-3 rounded-xl bg-orange-50 dark:bg-orange-900/10 border border-orange-200 dark:border-orange-800 text-xs text-orange-700 dark:text-orange-400">
            <div class="flex items-center gap-3">
              <.icon name="hero-cloud" class="w-4 h-4 shrink-0" />
              <span>
                Syncing to Cloudflare zone <code class="font-mono bg-orange-100 dark:bg-orange-900/30 px-1 rounded">
                  {@zone.cloudflare_zone_id}
                </code>. New records are pushed to Cloudflare automatically.
              </span>
            </div>
            <button
              id="sync-cf-footer-btn"
              phx-click="sync_to_cloudflare"
              class="shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-orange-200 hover:bg-orange-300 dark:bg-orange-900/40 dark:hover:bg-orange-900/60 text-orange-800 dark:text-orange-300 font-semibold transition-colors"
            >
              <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> Sync all to Cloudflare
            </button>
          </div>

          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 overflow-hidden">
            <div class="px-6 py-4 border-b border-gray-200 dark:border-gray-800 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h2 class="text-base font-semibold text-gray-900 dark:text-white">
                  Cloudflare Records
                </h2>
                <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
                  Review the live record set in Cloudflare and optionally import it into this local DNS zone.
                </p>
              </div>
              <div class="flex items-center gap-2">
                <button
                  id="refresh-cloudflare-records-btn"
                  phx-click="refresh_cloudflare_records"
                  class="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg bg-orange-100 hover:bg-orange-200 dark:bg-orange-900/20 dark:hover:bg-orange-900/30 text-orange-700 dark:text-orange-400 text-sm font-semibold transition-colors"
                >
                  <.icon name="hero-arrow-path" class="w-4 h-4" /> Refresh from Cloudflare
                </button>
                <button
                  id="import-cloudflare-records-btn"
                  phx-click="import_cloudflare_records"
                  class="inline-flex items-center gap-1.5 px-3 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-semibold transition-colors"
                >
                  <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Import to Local DNS
                </button>
              </div>
            </div>

            <%= if !@cloudflare_records_loaded do %>
              <div class="px-6 py-10 text-sm text-gray-500 dark:text-gray-400">
                Refresh Cloudflare records to inspect the live zone before importing.
              </div>
            <% else %>
              <%= if @cloudflare_records == [] do %>
                <div class="px-6 py-10 text-sm text-gray-500 dark:text-gray-400">
                  Cloudflare returned no DNS records for this zone.
                </div>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-800">
                    <thead>
                      <tr class="bg-gray-50 dark:bg-gray-800/50">
                        <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                          Type
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                          Name
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                          Value
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                          TTL
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                          Priority
                        </th>
                        <th class="px-4 py-3 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider">
                          Proxy
                        </th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-gray-100 dark:divide-gray-800">
                      <tr
                        :for={record <- @cloudflare_records}
                        class="hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors"
                      >
                        <td class="px-4 py-3">
                          <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-bold font-mono bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400">
                            {record["type"]}
                          </span>
                        </td>
                        <td class="px-4 py-3 font-mono text-sm text-gray-900 dark:text-white">
                          {record["name"]}
                        </td>
                        <td class="px-4 py-3 font-mono text-sm text-gray-600 dark:text-gray-300 max-w-xl truncate">
                          {record["content"]}
                        </td>
                        <td class="px-4 py-3 text-sm text-gray-500">{record["ttl"] || "—"}</td>
                        <td class="px-4 py-3 text-sm text-gray-500">{record["priority"] || "—"}</td>
                        <td class="px-4 py-3 text-sm text-gray-500">
                          <%= if Map.get(record, "proxied") do %>
                            Proxied
                          <% else %>
                            DNS only
                          <% end %>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
