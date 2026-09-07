defmodule HostctlWeb.CronLive.Index do
  use HostctlWeb, :live_view
  alias Hostctl.Hosting
  alias Hostctl.Hosting.CronJob
  alias HostctlWeb.ResourceScope

  def mount(_params, _session, socket) do
    domains = Hosting.list_domains(socket.assigns.current_scope)

    {:ok,
     assign(socket,
       domains: domains,
       selected_domain_id: nil,
       page_title: "Cron jobs",
       active_tab: :cron,
       editing: nil,
       form: nil,
       query: ""
     )}
  end

  def handle_params(params, _uri, socket) do
    domain = ResourceScope.selected(socket.assigns.domains, params["domain_id"])

    {:noreply,
     socket
     |> assign(:selected_domain_id, domain && domain.id)
     |> assign(:form, nil)
     |> load_jobs()}
  end

  def handle_event("scope_domain", %{"domain_id" => id}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/cron?#{%{domain_id: id}}")}

  def handle_event("search", %{"query" => query}, socket),
    do: {:noreply, socket |> assign(:query, query) |> load_jobs()}

  def handle_event("new", _, socket) do
    {:noreply,
     assign(socket,
       editing: nil,
       form: to_form(Hosting.change_cron_job(%CronJob{schedule: "0 3 * * *"}))
     )}
  end

  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, form: nil, editing: nil)}

  def handle_event("edit", %{"id" => id}, socket) do
    job = find_job!(socket, id)
    {:noreply, assign(socket, editing: job, form: to_form(Hosting.change_cron_job(job)))}
  end

  def handle_event("preset", %{"schedule" => schedule}, socket) do
    form =
      to_form(
        Hosting.change_cron_job(
          socket.assigns.editing || %CronJob{},
          Map.put(socket.assigns.form.params, "schedule", schedule)
        )
      )

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"cron_job" => params} = values, socket) do
    result =
      if socket.assigns.editing do
        Hosting.update_cron_job(find_job!(socket, socket.assigns.editing.id), params)
      else
        domain = ResourceScope.selected(socket.assigns.domains, values["domain_id"])

        if domain,
          do: Hosting.create_cron_job(domain, params),
          else:
            {:error,
             Hosting.change_cron_job(%CronJob{}, params)
             |> Ecto.Changeset.add_error(:command, "select a domain")}
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(form: nil, editing: nil)
         |> load_jobs()
         |> put_flash(:info, "Cron configuration saved.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    {:ok, _} = Hosting.delete_cron_job(find_job!(socket, id))
    {:noreply, socket |> load_jobs() |> put_flash(:info, "Cron job removed.")}
  end

  defp find_job!(socket, id) do
    Enum.flat_map(socket.assigns.domains, &Hosting.list_cron_jobs/1)
    |> Enum.find(&(to_string(&1.id) == to_string(id))) ||
      raise Ecto.NoResultsError, queryable: CronJob
  end

  defp load_jobs(socket) do
    jobs =
      socket.assigns.domains
      |> Enum.filter(
        &(is_nil(socket.assigns.selected_domain_id) || &1.id == socket.assigns.selected_domain_id)
      )
      |> Enum.flat_map(fn domain ->
        Enum.map(Hosting.list_cron_jobs(domain), &%{id: &1.id, job: &1, domain: domain})
      end)
      |> Enum.filter(
        &String.contains?(String.downcase(&1.job.command), String.downcase(socket.assigns.query))
      )

    socket |> assign(:job_count, length(jobs)) |> stream(:jobs, jobs, reset: true)
  end

  def schedule_label("0 * * * *"), do: "Every hour"
  def schedule_label("0 3 * * *"), do: "Daily at 03:00"
  def schedule_label("*/5 * * * *"), do: "Every 5 minutes"
  def schedule_label(_), do: "Custom schedule"

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab={:cron}
      update_status={assigns[:update_status]}
    >
      <div class="space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold">Cron jobs</h1>
            <p class="mt-1 text-sm text-gray-500">
              Scheduled command configuration for your websites.
            </p>
          </div>
          <button id="add-cron" phx-click="new" class="app-button" disabled={@domains == []}>
            Add cron job
          </button>
        </div>
        <HostctlWeb.ResourceComponents.domain_scope
          domains={@domains}
          selected_domain_id={@selected_domain_id}
          id="cron-scope"
        />
        <.form
          :if={@form}
          for={@form}
          id="cron-form"
          phx-submit="save"
          class="space-y-4 rounded-xl border border-gray-200 bg-white p-5 dark:border-gray-800 dark:bg-gray-900"
        >
          <.input
            :if={!@editing}
            type="select"
            name="domain_id"
            value={@selected_domain_id}
            label="Domain"
            options={Enum.map(@domains, &{&1.name, &1.id})}
          />
          <.input field={@form[:command]} type="textarea" label="Command" required />
          <.input field={@form[:schedule]} label="Cron expression" required />
          <p class="text-xs text-gray-500">
            Minute · Hour · Day of month · Month · Day of week. Times use the server's scheduler time zone.
          </p>
          <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
          <div class="flex gap-3">
            <button class="app-button" type="submit">Save configuration</button><button
              class="app-button"
              type="button"
              phx-click="cancel"
            >Cancel</button>
          </div>
        </.form>
        <.form for={to_form(%{"query" => @query})} id="cron-search" phx-change="search">
          <.input
            name="query"
            value={@query}
            type="search"
            label="Search commands"
            phx-debounce="200"
          />
        </.form>
        <div class="overflow-hidden rounded-xl border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-900">
          <div class="flex justify-between border-b border-gray-200 px-5 py-4 dark:border-gray-800">
            <h2 class="font-semibold">Scheduled jobs</h2>
            <span class="text-sm text-gray-500">{@job_count} jobs</span>
          </div>
          <div id="cron-jobs" phx-update="stream">
            <p id="cron-empty" class="hidden only:block p-6 text-sm text-gray-500">
              No matching jobs.
            </p>
            <div
              :for={{id, entry} <- @streams.jobs}
              id={id}
              class="flex flex-wrap items-center justify-between gap-4 border-b border-gray-100 p-5 dark:border-gray-800"
            >
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium">{entry.domain.name}</p>
                <code class="break-all text-xs">{entry.job.command}</code>
              </div>
              <div class="text-sm">
                <p>{schedule_label(entry.job.schedule)}</p>
                <code class="text-xs text-gray-500">{entry.job.schedule}</code>
                <p class="text-xs text-gray-500">
                  {if entry.job.enabled, do: "Enabled", else: "Paused"}
                </p>
              </div>
              <button
                id={"edit-cron-#{entry.id}"}
                phx-click="edit"
                phx-value-id={entry.id}
                class="text-sm text-indigo-600 dark:text-indigo-400"
              >
                Edit
              </button>
              <button
                phx-click="delete"
                phx-value-id={entry.id}
                data-confirm="Remove this cron job configuration?"
                class="text-sm text-red-600"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
