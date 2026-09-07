defmodule HostctlWeb.PanelLive.SpamProtectionLive do
  use HostctlWeb, :live_view
  alias Hostctl.SpamProtection
  alias Hostctl.SpamProtection.{Setting, MailboxPolicy}

  @impl true
  def mount(_, _, socket) do
    scope = socket.assigns.current_scope
    setting = SpamProtection.get_setting(scope)
    accounts = SpamProtection.list_mailboxes(scope)
    if connected?(socket), do: Process.send_after(self(), :refresh_status, 30_000)

    {:ok,
     socket
     |> assign(:page_title, "Spam Protection")
     |> assign(:setting_form, to_form(Setting.changeset(setting, %{})))
     |> assign(:policy_form, nil)
     |> assign(:selected_policy, nil)
     |> assign(:applying?, false)
     |> assign(:result, nil)
     |> assign(:mailboxes_empty?, accounts == [])
     |> assign(:status, %{
       enabled: false,
       healthy?: false,
       pending?: false,
       digest: nil,
       message: "Checking mail protection…"
     })
     |> stream(:mailboxes, accounts)
     |> start_status()}
  end

  @impl true
  def handle_event("save_setting", %{"setting" => params}, socket) do
    case SpamProtection.save_setting(socket.assigns.current_scope, params) do
      {:ok, setting} ->
        {:noreply,
         socket
         |> assign(:setting_form, to_form(Setting.changeset(setting, %{})))
         |> assign(:result, nil)
         |> put_flash(:info, "Settings saved. Apply saved settings to update mail protection.")
         |> start_status()}

      {:error, changeset} ->
        {:noreply, assign(socket, :setting_form, to_form(changeset))}
    end
  end

  def handle_event("select_mailbox", %{"id" => id}, socket) do
    policy = SpamProtection.get_policy(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> assign(:selected_policy, policy)
     |> assign(:policy_form, to_form(MailboxPolicy.changeset(policy, %{})))}
  rescue
    Ecto.NoResultsError -> {:noreply, put_flash(socket, :error, "That mailbox no longer exists.")}
  end

  def handle_event(
        "save_policy",
        %{"mailbox_policy" => params},
        %{assigns: %{selected_policy: policy}} = socket
      )
      when not is_nil(policy) do
    case SpamProtection.save_policy(socket.assigns.current_scope, policy.email_account_id, params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:selected_policy, updated)
         |> assign(:policy_form, to_form(MailboxPolicy.changeset(updated, %{})))
         |> put_flash(:info, "Mailbox rules saved. Apply saved settings to activate them.")
         |> start_status()}

      {:error, changeset} ->
        {:noreply, assign(socket, :policy_form, to_form(changeset))}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply,
       socket
       |> assign(:policy_form, nil)
       |> assign(:selected_policy, nil)
       |> put_flash(:error, "That mailbox no longer exists.")}
  end

  def handle_event("apply", _, %{assigns: %{applying?: true}} = socket), do: {:noreply, socket}

  def handle_event("apply", _, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:applying?, true)
     |> assign(:result, nil)
     |> start_async(:apply_spam, fn -> SpamProtection.apply(scope) end)}
  end

  def handle_event("refresh", _, socket), do: {:noreply, start_status(socket)}

  @impl true
  def handle_async(:apply_spam, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(:applying?, false)
     |> assign(
       :result,
       {:ok, "Saved settings applied. Mail services passed configuration and health checks."}
     )
     |> start_status()}
  end

  def handle_async(:apply_spam, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket |> assign(:applying?, false) |> assign(:result, {:error, reason}) |> start_status()}
  end

  def handle_async(:apply_spam, {:exit, _}, socket) do
    {:noreply,
     socket
     |> assign(:applying?, false)
     |> assign(
       :result,
       {:error, "Apply was interrupted. Refresh status and inspect the server before retrying."}
     )
     |> start_status()}
  end

  def handle_async(:spam_status, {:ok, status}, socket),
    do: {:noreply, assign(socket, :status, status)}

  def handle_async(:spam_status, {:exit, _}, socket) do
    {:noreply,
     assign(socket, :status, %{
       socket.assigns.status
       | healthy?: false,
         message: "Status check failed. Refresh to retry."
     })}
  end

  @impl true
  def handle_info(:refresh_status, socket) do
    Process.send_after(self(), :refresh_status, 30_000)
    {:noreply, if(socket.assigns.applying?, do: socket, else: start_status(socket))}
  end

  defp start_status(socket) do
    scope = socket.assigns.current_scope
    start_async(socket, :spam_status, fn -> SpamProtection.status(scope) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      update_status={assigns[:update_status]}
      flash={@flash}
      current_scope={@current_scope}
      active_tab={:panel_spam_protection}
    >
      <div id="spam-protection" class="mx-auto max-w-5xl space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <p class="text-xs font-semibold uppercase tracking-widest text-indigo-600 dark:text-indigo-400">
              Email security
            </p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-gray-900 dark:text-white">
              Spam Protection
            </h1>
            <p class="mt-2 text-sm text-gray-500 dark:text-gray-400">
              A quieter inbox, with filtering that learns from your corrections.
            </p>
          </div>
          <.icon name="hero-shield-check" class="size-12 text-indigo-500" />
        </div>

        <div
          id="spam-status"
          role="status"
          aria-live="polite"
          class="rounded-2xl border border-gray-200 bg-white p-6 shadow-sm dark:border-gray-800 dark:bg-gray-900"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <div class="flex items-center gap-2">
                <span class={[
                  "size-2.5 rounded-full",
                  if(@status.healthy?, do: "bg-emerald-500", else: "bg-amber-500")
                ]} />
                <h2 class="font-semibold text-gray-900 dark:text-white">
                  {cond do
                    @applying? -> "Applying saved settings…"
                    @status.healthy? -> "Protection is running"
                    @status.enabled -> "Protection needs attention"
                    true -> "Protection is not active"
                  end}
                </h2>
                <span
                  :if={@status.pending?}
                  id="spam-pending"
                  class="rounded-full bg-amber-100 px-2 py-1 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                >
                  Unapplied settings
                </span>
              </div>
              <p class="mt-2 max-w-2xl text-sm text-gray-500 dark:text-gray-400">{@status.message}</p>
            </div>
            <button
              id="refresh-spam-status"
              phx-click="refresh"
              disabled={@applying?}
              class="rounded-lg border border-gray-200 px-3 py-2 text-sm text-gray-600 transition hover:bg-gray-50 disabled:opacity-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
            >
              Refresh
            </button>
          </div>
          <div class="mt-5 flex flex-wrap items-center justify-between gap-4 border-t border-gray-100 pt-5 dark:border-gray-800">
            <p class="max-w-xl text-xs leading-5 text-gray-500 dark:text-gray-400">
              Apply installs required packages when enabling protection, validates configuration, and restarts mail services. Email clients may briefly reconnect. Disabling restores the original delivery settings and keeps learned data.
            </p>
            <button
              id="apply-spam-settings"
              phx-click="apply"
              disabled={@applying?}
              class="inline-flex items-center gap-2 rounded-lg bg-indigo-600 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-indigo-700 disabled:cursor-wait disabled:opacity-60"
            >
              <.icon
                name={if @applying?, do: "hero-arrow-path", else: "hero-check"}
                class={["size-4", @applying? && "animate-spin"]}
              />
              {if @applying?, do: "Applying…", else: "Apply saved settings"}
            </button>
          </div>
          <div
            :if={@result}
            id="spam-apply-result"
            role="alert"
            class={[
              "mt-4 whitespace-pre-wrap rounded-lg p-3 text-sm",
              if(elem(@result, 0) == :ok,
                do: "bg-emerald-50 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
                else: "bg-red-50 text-red-800 dark:bg-red-950 dark:text-red-300"
              )
            ]}
          >
            {elem(@result, 1)}
          </div>
        </div>

        <div class="grid gap-6 lg:grid-cols-5">
          <section class="rounded-2xl border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-900 lg:col-span-3">
            <h2 class="text-lg font-semibold text-gray-900 dark:text-white">Server defaults</h2>
            <p class="mb-5 mt-1 text-sm text-gray-500 dark:text-gray-400">
              Used for every mailbox unless you save an override below.
            </p>
            <.form
              for={@setting_form}
              id="spam-settings-form"
              phx-submit="save_setting"
              class="space-y-4"
            >
              <.input
                field={@setting_form[:enabled]}
                type="checkbox"
                label="Enable spam protection"
                disabled={@applying?}
              />
              <.input
                field={@setting_form[:learning]}
                type="checkbox"
                label="Learn from Junk and Inbox moves"
                disabled={@applying?}
              />
              <.input
                field={@setting_form[:junk_score]}
                type="number"
                min="1"
                max="20"
                step="1"
                label="Junk score threshold"
                disabled={@applying?}
              />
              <p class="text-xs leading-5 text-gray-500 dark:text-gray-400">
                Lower scores catch more spam but may catch wanted mail. Start at 6. Suspected spam goes to Junk; this policy never deletes messages or rejects them based on their spam score.
              </p>
              <button
                id="save-spam-settings"
                disabled={@applying?}
                class="rounded-lg bg-gray-900 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-gray-700 disabled:opacity-50 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-white"
              >
                Save defaults
              </button>
            </.form>
          </section>
          <aside class="rounded-2xl bg-indigo-50 p-6 dark:bg-indigo-950/30 lg:col-span-2">
            <h2 class="font-semibold text-indigo-950 dark:text-indigo-200">
              Teach it with your email app
            </h2>
            <ol class="mt-4 space-y-4 text-sm leading-6 text-indigo-900 dark:text-indigo-200">
              <li>
                <span class="font-semibold">1. Missed spam?</span>
                Move it into the server’s Junk folder.
              </li>
              <li>
                <span class="font-semibold">2. Wanted mail in Junk?</span> Move it back to Inbox.
              </li>
              <li>
                <span class="font-semibold">3. Give it examples.</span>
                Learning improves with both spam and legitimate mail. Corrections train a classifier shared by this server.
              </li>
            </ol>
            <p class="mt-5 border-t border-indigo-200 pt-4 text-xs leading-5 text-indigo-800 dark:border-indigo-900 dark:text-indigo-300">
              Use the IMAP folders named Junk and Inbox, including in webmail. Deleting mail or moving it to Trash does not train the filter. Learning does not automatically lower your threshold.
            </p>
          </aside>
        </div>

        <section class="rounded-2xl border border-gray-200 bg-white p-6 dark:border-gray-800 dark:bg-gray-900">
          <h2 class="text-lg font-semibold text-gray-900 dark:text-white">Mailbox rules</h2>
          <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
            Choose a mailbox to adjust sensitivity or add sender exceptions.
          </p>
          <div class="mt-5 grid gap-6 md:grid-cols-2">
            <div id="spam-mailboxes" phx-update="stream" class="max-h-80 space-y-2 overflow-y-auto">
              <p :if={@mailboxes_empty?} id="spam-no-mailboxes" class="text-sm text-gray-500">
                Create an email account to add mailbox rules.
              </p>
              <button
                :for={{id, account} <- @streams.mailboxes}
                id={id}
                phx-click="select_mailbox"
                phx-value-id={account.id}
                disabled={@applying?}
                class="flex w-full items-center gap-3 rounded-xl border border-gray-200 p-3 text-left text-sm text-gray-700 transition hover:border-indigo-300 hover:bg-indigo-50 disabled:opacity-50 dark:border-gray-800 dark:text-gray-200 dark:hover:bg-indigo-950/30"
              >
                <.icon name="hero-envelope" class="size-4 shrink-0 text-indigo-500" />
                <span class="truncate">{account.username}@{account.domain.name}</span>
              </button>
            </div>
            <div>
              <%= if @policy_form do %>
                <p
                  id="selected-spam-mailbox"
                  class="mb-4 break-all text-sm font-semibold text-gray-900 dark:text-white"
                >
                  {@selected_policy.email_account.username}@{@selected_policy.email_account.domain.name}
                </p>
                <.form
                  for={@policy_form}
                  id="spam-mailbox-form"
                  phx-submit="save_policy"
                  class="space-y-4"
                >
                  <.input
                    field={@policy_form[:junk_score]}
                    type="number"
                    min="1"
                    max="20"
                    step="1"
                    label="Junk score (blank uses server default)"
                    disabled={@applying?}
                  />
                  <.input
                    field={@policy_form[:allow_senders]}
                    type="textarea"
                    label="Allowed senders"
                    placeholder="sender@example.com"
                    disabled={@applying?}
                  />
                  <.input
                    field={@policy_form[:block_senders]}
                    type="textarea"
                    label="Always send to Junk"
                    placeholder="sender@example.com"
                    disabled={@applying?}
                  />
                  <p class="text-xs leading-5 text-gray-500 dark:text-gray-400">
                    One full address per line, up to 100 per list. Rules match the delivery envelope sender, which can differ from the displayed From address. Allowed senders bypass Junk sorting; an address match does not verify identity.
                  </p>
                  <button
                    id="save-spam-mailbox"
                    disabled={@applying?}
                    class="rounded-lg bg-indigo-600 px-4 py-2.5 text-sm font-medium text-white transition hover:bg-indigo-700 disabled:opacity-50"
                  >
                    Save mailbox rules
                  </button>
                </.form>
              <% else %>
                <p class="rounded-xl bg-gray-50 p-5 text-sm text-gray-500 dark:bg-gray-800 dark:text-gray-400">
                  Select a mailbox to view its rules.
                </p>
              <% end %>
            </div>
          </div>
        </section>
        <p class="text-xs leading-5 text-gray-500 dark:text-gray-400">
          To inspect a flagged message, open its original source in your email app. X-Hostctl-Junk-Reason explains the mailbox decision; X-Spamd-Result lists the filter tests and scores. Status refreshes every 30 seconds while this page is open.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
