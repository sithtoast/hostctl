defmodule HostctlWeb.PanelLive.EmailDeliveryLive do
  use HostctlWeb, :live_view
  alias Hostctl.EmailDelivery
  alias Hostctl.EmailDelivery.Setting

  @impl true
  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Email Delivery",
       selected: nil,
       form: nil,
       route: nil,
       plan: nil,
       busy: false,
       result: nil,
       checks?: false
     )
     |> stream(:domains, EmailDelivery.list_domains(socket.assigns.current_scope))
     |> stream(:records, [])
     |> stream(:checks, [])}
  end

  @impl true
  def handle_event(_, _, %{assigns: %{busy: true}} = socket), do: {:noreply, socket}

  def handle_event("select", %{"id" => id}, socket) do
    setting = EmailDelivery.get_setting(socket.assigns.current_scope, id)
    {:noreply, edit(socket, setting)}
  end

  def handle_event("preview", %{"setting" => attrs}, %{assigns: %{selected: selected}} = socket)
      when not is_nil(selected) do
    scope = socket.assigns.current_scope

    case EmailDelivery.save(scope, selected.domain_id, attrs) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> edit(setting)
         |> work(:preview, fn -> EmailDelivery.preview(scope, setting.domain_id) end)}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset), plan: nil)
         |> stream(:records, [], reset: true)}
    end
  end

  def handle_event("prepare_key", _, %{assigns: %{selected: selected}} = socket)
      when not is_nil(selected) do
    scope = socket.assigns.current_scope
    {:noreply, work(socket, :key, fn -> EmailDelivery.prepare_key(scope, selected.domain_id) end)}
  end

  def handle_event("enable_signing", _, %{assigns: %{selected: selected}} = socket)
      when not is_nil(selected) do
    scope = socket.assigns.current_scope

    {:noreply,
     work(socket, :signing, fn -> EmailDelivery.enable_signing(scope, selected.domain_id) end)}
  end

  def handle_event("publish", _, %{assigns: %{plan: plan}} = socket) when not is_nil(plan) do
    scope = socket.assigns.current_scope
    {:noreply, work(socket, :publish, fn -> EmailDelivery.publish(scope, plan) end)}
  end

  def handle_event("verify", _, %{assigns: %{plan: plan}} = socket) when not is_nil(plan) do
    scope = socket.assigns.current_scope
    {:noreply, work(socket, :verify, fn -> EmailDelivery.verify(scope, plan) end)}
  end

  @impl true
  def handle_async(:preview, {:ok, {:ok, plan}}, socket) do
    {:noreply,
     socket |> assign(busy: false, plan: plan) |> stream(:records, plan.rows, reset: true)}
  end

  def handle_async(:key, {:ok, {:ok, setting}}, socket) do
    {:noreply,
     socket
     |> edit(setting)
     |> assign(
       busy: false,
       result:
         {:ok,
          "Public key prepared. Preview and publish its DNS record, then verify before enabling signing."}
     )}
  end

  def handle_async(:verify, {:ok, checks}, socket) do
    {:noreply,
     socket |> assign(busy: false, checks?: true) |> stream(:checks, checks, reset: true)}
  end

  def handle_async(:publish, {:ok, result}, socket) do
    scope = socket.assigns.current_scope
    plan = socket.assigns.plan
    socket = assign(socket, busy: false, result: result)

    {:noreply,
     if(elem(result, 0) == :ok,
       do: work(socket, :verify, fn -> EmailDelivery.verify(scope, plan) end),
       else: socket
     )}
  end

  def handle_async(_name, {:ok, result}, socket),
    do: {:noreply, assign(socket, busy: false, result: result)}

  def handle_async(_name, {:exit, _}, socket) do
    {:noreply,
     assign(socket,
       busy: false,
       result:
         {:error,
          "Operation interrupted. Check DNS/server state and preview again before retrying."}
     )}
  end

  defp work(socket, name, fun), do: socket |> assign(busy: true) |> start_async(name, fun)

  defp edit(socket, setting) do
    socket
    |> assign(
      selected: setting,
      form: to_form(Setting.changeset(setting, %{})),
      route: EmailDelivery.route(socket.assigns.current_scope, setting),
      plan: nil,
      result: nil,
      checks?: false
    )
    |> stream(:records, [], reset: true)
    |> stream(:checks, [], reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      update_status={assigns[:update_status]}
      flash={@flash}
      current_scope={@current_scope}
      active_tab={:panel_email_delivery}
    >
      <div id="email-delivery" class="mx-auto max-w-6xl space-y-6">
        <div class="flex items-start justify-between gap-5">
          <div>
            <p class="text-xs font-semibold uppercase tracking-widest text-indigo-600 dark:text-indigo-400">
              Email security
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-gray-900 dark:text-white">
              Email Delivery
            </h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-gray-500 dark:text-gray-400">
              Authorize your senders, publish signing keys, and check what the rest of the internet sees.
            </p>
          </div>
          <.icon name="hero-paper-airplane" class="size-10 text-indigo-500" />
        </div>
        <div class="grid gap-6 lg:grid-cols-4">
          <aside class="rounded-2xl border border-gray-200 bg-white p-4 dark:border-gray-800 dark:bg-gray-900">
            <h2 class="mb-3 text-sm font-semibold text-gray-900 dark:text-white">Choose a domain</h2>
            <div id="delivery-domains" phx-update="stream" class="space-y-2">
              <p id="delivery-no-domains" class="hidden text-sm text-gray-500 only:block">
                Add a domain to configure email delivery.
              </p>
              <button
                :for={{id, domain} <- @streams.domains}
                id={id}
                phx-click="select"
                phx-value-id={domain.id}
                disabled={@busy}
                class="w-full break-all rounded-lg px-3 py-2 text-left text-sm text-gray-700 transition hover:bg-indigo-50 hover:text-indigo-700 disabled:opacity-50 dark:text-gray-200 dark:hover:bg-indigo-950"
              >
                {domain.name}
              </button>
            </div>
          </aside>
          <section class="space-y-5 lg:col-span-3">
            <div
              :if={!@selected}
              id="delivery-empty"
              class="rounded-2xl bg-indigo-50 p-8 text-sm leading-6 text-indigo-900 dark:bg-indigo-950/30 dark:text-indigo-200"
            >
              Select a domain to review its outgoing mail route and DNS. Existing MX records stay in place, and existing DMARC enforcement is preserved.
            </div>
            <div
              :if={@selected}
              class="rounded-2xl border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-900"
            >
              <h2 class="text-lg font-semibold text-gray-900 dark:text-white">
                {@selected.domain.name}
              </h2>
              <p id="delivery-route" class="mt-1 text-sm text-gray-500">
                Configured route: {if elem(@route, 0) == :direct,
                  do: "Direct from this server",
                  else: "Relay through #{elem(@route, 1)}"}
              </p>
              <.form for={@form} id="delivery-form" phx-submit="preview" class="mt-5 space-y-4">
                <%= if elem(@route, 0) == :direct do %>
                  <.input
                    field={@form[:hostname]}
                    label="Mail server hostname / HELO"
                    placeholder="mail.example.com"
                    disabled={@busy}
                  />
                  <div class="grid gap-4 sm:grid-cols-2">
                    <.input
                      field={@form[:ipv4]}
                      label="Public outbound IPv4"
                      placeholder="203.0.113.10"
                      disabled={@busy}
                    />
                    <.input
                      field={@form[:ipv6]}
                      label="Public outbound IPv6 (if used)"
                      disabled={@busy}
                    />
                  </div>
                  <p class="text-xs leading-5 text-gray-500">
                    Use the actual public egress IPs, including NAT and IPv6. PTR is controlled by your IP hosting provider. These settings do not change Postfix routing or HELO.
                  </p>
                <% else %>
                  <.input
                    field={@form[:spf_include]}
                    label="Relay provider’s SPF include hostname"
                    placeholder="mailgun.org"
                    disabled={@busy}
                  />
                  <.input
                    field={@form[:dkim_records]}
                    type="textarea"
                    rows="4"
                    label="Relay provider’s DKIM records (one per line)"
                    placeholder={"selector._domainkey.#{@selected.domain.name} CNAME provider-hostname.example.com"}
                    disabled={@busy}
                  />
                  <p class="text-xs leading-5 text-gray-500">
                    Copy the records from the provider’s domain settings. Use a full record name followed by TXT and its unquoted value, or CNAME and its target. Keep inbound MX records with your mailbox provider.
                  </p>
                <% end %>
                <button
                  id="preview-delivery"
                  disabled={@busy}
                  class="rounded-lg bg-indigo-600 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-indigo-700 disabled:opacity-50"
                >
                  Save and preview DNS
                </button>
              </.form>
              <div
                :if={elem(@route, 0) == :direct}
                class="mt-5 flex flex-wrap items-center gap-3 border-t border-gray-100 pt-5 dark:border-gray-800"
              >
                <button
                  id="prepare-delivery-key"
                  phx-click="prepare_key"
                  disabled={@busy}
                  class="rounded-lg border border-gray-200 px-3 py-2 text-sm text-gray-700 transition hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                >
                  Prepare DKIM key
                </button>
                <button
                  :if={@selected.selector}
                  id="enable-delivery-signing"
                  phx-click="enable_signing"
                  disabled={@busy}
                  class="rounded-lg border border-gray-200 px-3 py-2 text-sm text-gray-700 transition hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                >
                  Enable signing after DNS verification
                </button>
                <p class="w-full text-xs leading-5 text-gray-500">
                  Requires applied <.link navigate={~p"/panel/spam-protection"} class="underline">Spam Protection</.link>. Signing uses authenticated SMTP with a matching sender domain. Websites must submit through authenticated SMTP. Enabling applies mail configuration and briefly reconnects email clients.
                </p>
              </div>
            </div>
            <div
              :if={@busy}
              id="delivery-busy"
              role="status"
              class="flex items-center gap-2 text-sm text-indigo-600"
            >
              <.icon name="hero-arrow-path" class="size-4 animate-spin" />
              Working… DNS checks can take a moment.
            </div>
            <p
              :if={@result}
              id="delivery-result"
              role="alert"
              class={[
                "rounded-xl p-4 text-sm",
                if(elem(@result, 0) == :ok,
                  do: "bg-emerald-50 text-emerald-800",
                  else: "bg-amber-50 text-amber-900"
                )
              ]}
            >
              {elem(@result, 1)}
            </p>
            <div class="space-y-4" hidden={!@plan}>
              <h2 class="text-lg font-semibold text-gray-900 dark:text-white">Review DNS changes</h2>
              <p class="text-xs leading-5 text-gray-500">
                New SPF policies start with softfail; new DMARC policies start at p=none. Existing policies are preserved. Preview expires after 15 minutes. Records below can also be copied to another DNS provider.
              </p>
              <div id="delivery-records" phx-update="stream" class="space-y-3">
                <article
                  :for={{id, row} <- @streams.records}
                  id={id}
                  class="rounded-xl border border-gray-200 bg-white p-4 dark:border-gray-800 dark:bg-gray-900"
                >
                  <div class="flex flex-wrap justify-between gap-2">
                    <span class="text-sm font-semibold text-gray-900 dark:text-white">
                      {row.label} · {row.type}
                    </span>
                    <span class="text-xs font-medium uppercase text-indigo-600">{row.action}</span>
                  </div>
                  <p class="mt-2 break-all font-mono text-xs text-gray-600 dark:text-gray-300">
                    {row.name}
                  </p>
                  <p
                    :if={row.before && row.before.value != row.value}
                    class="mt-2 break-all text-xs text-gray-500"
                  >
                    Current: {row.before.value}
                  </p>
                  <pre
                    :if={row.value != ""}
                    class="mt-2 whitespace-pre-wrap break-all rounded-lg bg-gray-50 p-3 text-xs text-gray-800 dark:bg-gray-800 dark:text-gray-100"
                  >{row.value}</pre>
                  <p class="mt-2 text-xs leading-5 text-gray-500">{row.reason}</p>
                </article>
              </div>
              <div class="flex flex-wrap gap-3">
                <button
                  :if={@plan && @plan.source.provider == :cloudflare}
                  id="publish-delivery"
                  phx-click="publish"
                  disabled={@busy || Enum.any?(@plan.rows, &(&1.action == :blocked))}
                  class="rounded-lg bg-indigo-600 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-indigo-700 disabled:opacity-50"
                >
                  Publish reviewed changes to Cloudflare
                </button>
                <button
                  id="verify-delivery"
                  phx-click="verify"
                  disabled={@busy}
                  class="rounded-lg border border-gray-200 px-4 py-2.5 text-sm font-medium text-gray-700 transition hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                >
                  Verify public DNS
                </button>
              </div>
            </div>
            <section hidden={!@checks?} class="space-y-3">
              <h2 class="text-lg font-semibold text-gray-900 dark:text-white">Public DNS checks</h2>
              <div id="delivery-checks" phx-update="stream" class="space-y-2">
                <div
                  :for={{id, check} <- @streams.checks}
                  id={id}
                  class="rounded-xl border border-gray-200 p-4 dark:border-gray-800"
                >
                  <p class="text-sm font-medium text-gray-900 dark:text-white">{check.name}</p>
                  <p class={[
                    "mt-1 text-xs leading-5",
                    if(check.result == :ok, do: "text-emerald-600", else: "text-amber-600")
                  ]}>
                    {if check.result == :ok, do: "Verified in public DNS", else: elem(check.result, 1)}
                  </p>
                </div>
              </div>
            </section>
          </section>
        </div>
        <p class="text-xs leading-5 text-gray-500">
          Authentication improves delivery and reduces spoofing. It cannot guarantee inbox placement or prevent blocklisting caused by abusive sending. After setup, send a real test email and inspect its SPF, DKIM and DMARC results.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
