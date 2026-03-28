defmodule HostctlWeb.PanelLive.Users do
  use HostctlWeb, :live_view

  alias Hostctl.Accounts
  alias Hostctl.Accounts.User

  # JS hook name for clipboard copy
  @copy_hook ".CopyToClipboard"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={:panel_users}>
      <div class="max-w-4xl mx-auto space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Panel Users</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Manage users who can add and configure their own domains.
            </p>
          </div>
          <button
            id="open-new-user-btn"
            phx-click="toggle_form"
            class="flex items-center gap-2 px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> Invite User
          </button>
        </div>

        <%!-- New user form --%>
        <%= if @show_form do %>
          <div
            id="new-user-form-panel"
            class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-6 shadow-sm"
          >
            <h2 class="text-base font-semibold text-gray-900 dark:text-white mb-4">
              Invite a new panel user
            </h2>
            <.form for={@form} id="new-user-form" phx-submit="create_user" phx-change="validate">
              <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Full Name"
                  placeholder="Jane Smith"
                  autocomplete="name"
                  required
                />
                <.input
                  field={@form[:email]}
                  type="email"
                  label="Email Address"
                  placeholder="jane@example.com"
                  autocomplete="email"
                  spellcheck="false"
                  required
                />
              </div>
              <div class="flex items-center gap-3 mt-4">
                <button
                  type="submit"
                  phx-disable-with="Sending invite..."
                  class="px-4 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium transition-colors"
                >
                  Send Invite
                </button>
                <button
                  type="button"
                  phx-click="toggle_form"
                  class="px-4 py-2 rounded-lg border border-gray-200 dark:border-gray-700 text-gray-700 dark:text-gray-300 text-sm font-medium hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </div>
        <% end %>

        <%!-- Magic link banner --%>
        <%= if @magic_link do %>
          <div
            id="magic-link-banner"
            class="rounded-xl border border-indigo-200 dark:border-indigo-800 bg-indigo-50 dark:bg-indigo-950/50 p-4 flex flex-col gap-3"
          >
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="text-sm font-medium text-indigo-900 dark:text-indigo-200">
                  Login link for {@magic_link_name}
                </p>
                <p class="text-xs text-indigo-600 dark:text-indigo-400 mt-0.5">
                  Share this link with the user. It expires after one use.
                </p>
              </div>
              <button
                phx-click="dismiss_magic_link"
                class="text-indigo-400 hover:text-indigo-600 dark:hover:text-indigo-300 transition-colors shrink-0"
                aria-label="Dismiss"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
            <div class="flex items-center gap-2">
              <input
                id="magic-link-input"
                type="text"
                readonly
                value={@magic_link}
                class="flex-1 text-xs font-mono bg-white dark:bg-gray-900 border border-indigo-200 dark:border-indigo-700 rounded-lg px-3 py-2 text-gray-700 dark:text-gray-300 select-all focus:outline-none focus:ring-2 focus:ring-indigo-500"
              />
              <button
                id="copy-magic-link-btn"
                phx-hook={@copy_hook}
                data-target="#magic-link-input"
                class="flex items-center gap-1.5 px-3 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-medium transition-colors shrink-0"
              >
                <.icon name="hero-clipboard" class="w-3.5 h-3.5" /> Copy
              </button>
            </div>
          </div>
        <% end %>

        <%!-- User list --%>
        <div class="rounded-xl border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 shadow-sm overflow-hidden">
          <%= if @users_empty? do %>
            <div
              id="panel-users-empty"
              class="flex items-center justify-center py-16 text-gray-400 dark:text-gray-600"
            >
              <div class="text-center space-y-2">
                <.icon name="hero-users" class="w-10 h-10 mx-auto" />
                <p class="text-sm">No panel users yet. Invite your first user.</p>
              </div>
            </div>
          <% end %>
          <div id="panel-users-list" phx-update="stream">
            <div
              :for={{id, user} <- @streams.panel_users}
              id={id}
              class="flex items-center gap-4 px-6 py-4 border-b border-gray-100 dark:border-gray-800 last:border-b-0 hover:bg-gray-50 dark:hover:bg-gray-800/50 transition-colors group"
            >
              <div class="flex items-center justify-center w-9 h-9 rounded-full bg-indigo-100 dark:bg-indigo-900/50 text-indigo-700 dark:text-indigo-300 text-sm font-semibold shrink-0">
                {String.upcase(String.slice(user.name || user.email, 0, 1))}
              </div>
              <div class="flex-1 min-w-0">
                <p class="text-sm font-medium text-gray-900 dark:text-white truncate">
                  {if user.name && user.name != "", do: user.name, else: "(no name)"}
                </p>
                <p class="text-xs text-gray-500 dark:text-gray-400 truncate">{user.email}</p>
              </div>
              <div class="flex items-center gap-3 shrink-0">
                <%= if user.confirmed_at do %>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 dark:bg-green-900/40 text-green-700 dark:text-green-400">
                    <span class="w-1.5 h-1.5 rounded-full bg-green-500 inline-block"></span> Active
                  </span>
                <% else %>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-amber-100 dark:bg-amber-900/40 text-amber-700 dark:text-amber-400">
                    <span class="w-1.5 h-1.5 rounded-full bg-amber-400 inline-block"></span> Pending
                  </span>
                <% end %>
                <p class="text-xs text-gray-400 dark:text-gray-500 hidden sm:block">
                  Joined {Calendar.strftime(user.inserted_at, "%b %-d, %Y")}
                </p>
                <.link
                  phx-click="get_magic_link"
                  phx-value-id={user.id}
                  class="opacity-0 group-hover:opacity-100 text-xs text-indigo-500 hover:text-indigo-700 dark:text-indigo-400 dark:hover:text-indigo-300 transition-all"
                  title="Get a login link to share"
                >
                  Get login link
                </.link>
                <.link
                  phx-click="resend_invite"
                  phx-value-id={user.id}
                  class="opacity-0 group-hover:opacity-100 text-xs text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 transition-all"
                  title="Resend invite email"
                >
                  Resend email
                </.link>
                <button
                  phx-click="delete_user"
                  phx-value-id={user.id}
                  data-confirm={"Are you sure you want to delete #{user.email}? This cannot be undone."}
                  class="opacity-0 group-hover:opacity-100 text-gray-400 hover:text-red-500 dark:hover:text-red-400 transition-all"
                  title="Delete user"
                >
                  <.icon name="hero-trash" class="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const targetId = this.el.dataset.target
            const input = document.querySelector(targetId)
            if (!input) return
            navigator.clipboard.writeText(input.value).then(() => {
              const original = this.el.innerHTML
              this.el.innerHTML = "<span class=\"hero-check w-3.5 h-3.5 inline-block\"></span> Copied!"
              setTimeout(() => { this.el.innerHTML = original }, 2000)
            })
          })
        }
      }
    </script>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    changeset = Accounts.change_panel_user(%User{}, %{}, validate_unique: false)

    users = Accounts.list_panel_users()

    socket =
      socket
      |> assign(:show_form, false)
      |> assign(:users_empty?, users == [])
      |> assign(:magic_link, nil)
      |> assign(:magic_link_name, nil)
      |> assign(:copy_hook, @copy_hook)
      |> assign_form(changeset)
      |> stream(:panel_users, users)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    changeset = Accounts.change_panel_user(%User{}, %{}, validate_unique: false)

    socket =
      socket
      |> assign(:show_form, !socket.assigns.show_form)
      |> assign_form(changeset)

    {:noreply, socket}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset = Accounts.change_panel_user(%User{}, params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("create_user", %{"user" => params}, socket) do
    case Accounts.create_panel_user(params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        socket =
          socket
          |> put_flash(:info, "Invite sent to #{user.email}.")
          |> assign(:show_form, false)
          |> assign(:users_empty?, false)
          |> stream_insert(:panel_users, user, at: 0)
          |> assign_form(Accounts.change_panel_user(%User{}, %{}, validate_unique: false))

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("get_magic_link", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    token = Accounts.generate_magic_link_token(user)
    link = url(~p"/users/log-in/#{token}")
    name = if user.name && user.name != "", do: user.name, else: user.email

    socket =
      socket
      |> assign(:magic_link, link)
      |> assign(:magic_link_name, name)

    {:noreply, socket}
  end

  def handle_event("dismiss_magic_link", _params, socket) do
    {:noreply, assign(socket, magic_link: nil, magic_link_name: nil)}
  end

  def handle_event("resend_invite", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    {:ok, _} =
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )

    {:noreply, put_flash(socket, :info, "Invite resent to #{user.email}.")}
  end

  def handle_event("delete_user", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    case Accounts.delete_user(user) do
      {:ok, _} ->
        remaining = Accounts.list_panel_users()

        socket =
          socket
          |> put_flash(:info, "User #{user.email} deleted.")
          |> assign(:users_empty?, remaining == [])
          |> stream_delete(:panel_users, user)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete user.")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end
end
