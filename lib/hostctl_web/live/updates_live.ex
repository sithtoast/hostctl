defmodule HostctlWeb.UpdatesLive do
  use HostctlWeb, :live_view

  alias Hostctl.Updater

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Updates")
      |> assign(:check_status, :loading)
      |> assign(:update_info, nil)

    if connected?(socket), do: send(self(), :check_updates)

    {:ok, socket}
  end

  @impl true
  def handle_info(:check_updates, socket) do
    socket =
      case Updater.check_for_updates() do
        {:ok, info} ->
          socket
          |> assign(:check_status, :ok)
          |> assign(:update_info, info)

        {:error, reason} ->
          socket
          |> assign(:check_status, {:error, reason})
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab={:updates}>
      <div class="max-w-3xl mx-auto space-y-6">
        <%!-- Page header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 dark:text-white">Updates</h1>
            <p class="mt-1 text-sm text-gray-500 dark:text-gray-400">
              Check for new versions and view release notes.
            </p>
          </div>
          <%= if @check_status != :loading do %>
            <button
              id="recheck-btn"
              phx-click="recheck"
              class="inline-flex items-center gap-2 px-3 py-2 text-sm font-medium text-gray-600 dark:text-gray-300 bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-700 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-800 transition-colors"
            >
              <.icon name="hero-arrow-path" class="w-4 h-4" /> Check again
            </button>
          <% end %>
        </div>

        <%!-- Status card --%>
        <%= cond do %>
          <% @check_status == :loading -> %>
            <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800 p-10 flex flex-col items-center justify-center gap-3 text-gray-400">
              <div class="animate-spin rounded-full h-7 w-7 border-2 border-indigo-500 border-t-transparent">
              </div>
              <span class="text-sm">Checking for updates…</span>
            </div>
          <% @check_status == :ok and @update_info.has_update -> %>
            <%!-- Update available --%>
            <div class="bg-amber-50 dark:bg-amber-950/30 border border-amber-200 dark:border-amber-800 rounded-xl p-6">
              <div class="flex items-start gap-4">
                <div class="flex items-center justify-center w-10 h-10 rounded-full bg-amber-100 dark:bg-amber-900/50 shrink-0 mt-0.5">
                  <.icon
                    name="hero-arrow-up-circle"
                    class="w-5 h-5 text-amber-600 dark:text-amber-400"
                  />
                </div>
                <div class="flex-1 min-w-0">
                  <p class="text-base font-semibold text-amber-900 dark:text-amber-200">
                    Update available — v{@update_info.release.name}
                    <%= if @update_info.release.prerelease do %>
                      <span class="ml-2 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-purple-100 dark:bg-purple-900/50 text-purple-700 dark:text-purple-300 border border-purple-200 dark:border-purple-700">
                        pre-release
                      </span>
                    <% end %>
                  </p>
                  <p class="mt-1 text-sm text-amber-700 dark:text-amber-400">
                    A new version of hostctl has been published.
                  </p>
                  <div class="mt-3 flex flex-wrap items-center gap-2 text-xs font-mono">
                    <span class="px-2.5 py-1 rounded-full bg-white/60 dark:bg-gray-800 text-gray-600 dark:text-gray-400 border border-gray-200 dark:border-gray-700">
                      current: v{@update_info.current}
                    </span>
                    <.icon name="hero-arrow-right" class="w-3.5 h-3.5 text-amber-500" />
                    <span class="px-2.5 py-1 rounded-full bg-amber-100 dark:bg-amber-900/60 text-amber-800 dark:text-amber-200 border border-amber-300 dark:border-amber-700 font-semibold">
                      latest: v{@update_info.latest}
                    </span>
                  </div>
                  <%= if @update_info.release.published_at do %>
                    <p class="mt-2 text-xs text-amber-600 dark:text-amber-500">
                      Released {format_date(@update_info.release.published_at)}
                    </p>
                  <% end %>
                  <div class="mt-4">
                    <a
                      href={@update_info.release.html_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="inline-flex items-center gap-1.5 text-sm font-medium text-amber-700 dark:text-amber-300 hover:underline"
                    >
                      View on GitHub
                      <.icon name="hero-arrow-top-right-on-square" class="w-3.5 h-3.5" />
                    </a>
                  </div>
                </div>
              </div>
            </div>
          <% @check_status == :ok -> %>
            <%!-- Up to date --%>
            <div class="bg-emerald-50 dark:bg-emerald-950/30 border border-emerald-200 dark:border-emerald-800 rounded-xl p-6">
              <div class="flex items-start gap-4">
                <div class="flex items-center justify-center w-10 h-10 rounded-full bg-emerald-100 dark:bg-emerald-900/50 shrink-0 mt-0.5">
                  <.icon
                    name="hero-check-circle"
                    class="w-5 h-5 text-emerald-600 dark:text-emerald-400"
                  />
                </div>
                <div>
                  <p class="text-base font-semibold text-emerald-900 dark:text-emerald-200">
                    hostctl is up to date
                    <%= if @update_info.release.prerelease do %>
                      <span class="ml-2 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-purple-100 dark:bg-purple-900/50 text-purple-700 dark:text-purple-300 border border-purple-200 dark:border-purple-700">
                        pre-release
                      </span>
                    <% end %>
                  </p>
                  <p class="mt-1 text-sm text-emerald-700 dark:text-emerald-400">
                    You are running the latest version.
                  </p>
                  <span class="mt-3 inline-flex items-center px-2.5 py-1 rounded-full bg-emerald-100 dark:bg-emerald-900/60 text-emerald-800 dark:text-emerald-200 border border-emerald-200 dark:border-emerald-700 text-xs font-mono font-semibold">
                    v{@update_info.current}
                  </span>
                  <%= if @update_info.release.published_at do %>
                    <p class="mt-2 text-xs text-emerald-600 dark:text-emerald-500">
                      Released {format_date(@update_info.release.published_at)}
                    </p>
                  <% end %>
                </div>
              </div>
            </div>
          <% @check_status == {:error, :not_configured} -> %>
            <%!-- Not configured --%>
            <div class="bg-blue-50 dark:bg-blue-950/30 border border-blue-200 dark:border-blue-800 rounded-xl p-6">
              <div class="flex items-start gap-4">
                <div class="flex items-center justify-center w-10 h-10 rounded-full bg-blue-100 dark:bg-blue-900/50 shrink-0 mt-0.5">
                  <.icon
                    name="hero-information-circle"
                    class="w-5 h-5 text-blue-600 dark:text-blue-400"
                  />
                </div>
                <div class="flex-1">
                  <p class="text-base font-semibold text-blue-900 dark:text-blue-200">
                    GitHub repository not configured
                  </p>
                  <p class="mt-1 text-sm text-blue-700 dark:text-blue-400">
                    Add your repo to enable update checks.
                  </p>
                  <div class="mt-4 rounded-lg bg-gray-900 dark:bg-gray-950 px-4 py-3">
                    <pre
                      id="config-snippet"
                      class="text-sm text-gray-100 font-mono"
                    >{config_snippet_html()}</pre>
                  </div>
                </div>
              </div>
            </div>
          <% @check_status == {:error, :no_releases} -> %>
            <%!-- No releases yet --%>
            <div class="bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-800 rounded-xl p-6">
              <div class="flex items-start gap-4">
                <div class="flex items-center justify-center w-10 h-10 rounded-full bg-gray-100 dark:bg-gray-800 shrink-0 mt-0.5">
                  <.icon name="hero-tag" class="w-5 h-5 text-gray-400 dark:text-gray-500" />
                </div>
                <div>
                  <p class="text-base font-semibold text-gray-900 dark:text-gray-200">
                    No releases published yet
                  </p>
                  <p class="mt-1 text-sm text-gray-600 dark:text-gray-400">
                    The repository is configured correctly. Update checks will work once
                    you publish a release on GitHub.
                  </p>
                  <span class="mt-3 inline-flex items-center gap-1.5 text-xs font-mono text-gray-500 dark:text-gray-400">
                    <.icon name="hero-code-bracket" class="w-3.5 h-3.5" />
                    {Application.get_env(:hostctl, :github_repo)}
                  </span>
                </div>
              </div>
            </div>
          <% true -> %>
            <%!-- Error --%>
            <div class="bg-red-50 dark:bg-red-950/30 border border-red-200 dark:border-red-800 rounded-xl p-6">
              <div class="flex items-start gap-4">
                <div class="flex items-center justify-center w-10 h-10 rounded-full bg-red-100 dark:bg-red-900/50 shrink-0 mt-0.5">
                  <.icon
                    name="hero-exclamation-triangle"
                    class="w-5 h-5 text-red-600 dark:text-red-400"
                  />
                </div>
                <div>
                  <p class="text-base font-semibold text-red-900 dark:text-red-200">
                    Could not check for updates
                  </p>
                  <p class="mt-1 text-sm text-red-700 dark:text-red-400">
                    {error_message(@check_status)}
                  </p>
                </div>
              </div>
            </div>
        <% end %>

        <%!-- Release notes --%>
        <%= if @check_status == :ok and @update_info.release.body not in [nil, ""] do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-4 border-b border-gray-100 dark:border-gray-800">
              <h2 class="text-sm font-semibold text-gray-900 dark:text-white">Release notes</h2>
            </div>
            <div class="px-6 py-5">
              <pre
                id="release-notes"
                class="text-sm text-gray-700 dark:text-gray-300 whitespace-pre-wrap font-sans leading-relaxed"
              >{@update_info.release.body}</pre>
            </div>
          </div>
        <% end %>

        <%!-- Update instructions --%>
        <%= if @check_status == :ok and @update_info.has_update do %>
          <div class="bg-white dark:bg-gray-900 rounded-xl border border-gray-200 dark:border-gray-800">
            <div class="px-6 py-4 border-b border-gray-100 dark:border-gray-800">
              <h2 class="text-sm font-semibold text-gray-900 dark:text-white">How to update</h2>
            </div>
            <div class="px-6 py-5 space-y-4">
              <p class="text-sm text-gray-600 dark:text-gray-400">
                Run the following commands on your server to update hostctl:
              </p>
              <div class="rounded-lg bg-gray-900 dark:bg-gray-950 p-4 overflow-x-auto">
                <pre
                  id="update-instructions"
                  class="text-sm text-gray-100 font-mono leading-relaxed"
                >{update_commands_html()}</pre>
              </div>
              <p class="text-xs text-gray-400 dark:text-gray-500">
                If you are using a release, rebuild and restart with your deployment workflow instead.
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Version info footer --%>
        <div class="flex items-center justify-between py-2 text-xs text-gray-400 dark:text-gray-600">
          <span>hostctl v{Updater.current_version()}</span>
          <span>
            Elixir {System.version()} · OTP {:erlang.system_info(:otp_release) |> to_string()}
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("recheck", _params, socket) do
    socket =
      socket
      |> assign(:check_status, :loading)
      |> assign(:update_info, nil)

    send(self(), :check_updates)

    {:noreply, socket}
  end

  # --- Private helpers ---

  defp format_date(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        "#{dt.day} #{month_name(dt.month)} #{dt.year}"

      _ ->
        iso_string
    end
  end

  defp month_name(m) do
    ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec) |> Enum.at(m - 1)
  end

  defp error_message({:error, :no_releases}),
    do: "No releases found. Make sure the GitHub repository is configured correctly."

  defp error_message({:error, :rate_limited}),
    do: "GitHub API rate limit exceeded. Please try again later."

  defp error_message({:error, {:unexpected_status, code}}),
    do: "Unexpected response from GitHub (HTTP #{code})."

  defp error_message({:error, _}),
    do: "Unable to reach GitHub. Check your server's internet connection."

  defp error_message(_), do: "An unexpected error occurred."

  defp config_snippet_html do
    ~s(# config/config.exs\nconfig :hostctl, :github_repo, "your-org/hostctl")
    |> Phoenix.HTML.raw()
  end

  defp update_commands_html do
    comment = fn text -> ~s(<span class="text-gray-500">#{text}</span>) end

    [
      comment.("# Pull latest changes"),
      "git pull origin main",
      "",
      comment.("# Install new dependencies"),
      "mix deps.get --only prod",
      "",
      comment.("# Run database migrations"),
      "MIX_ENV=prod mix ecto.migrate",
      "",
      comment.("# Restart the application"),
      "MIX_ENV=prod mix phx.server"
    ]
    |> Enum.join("\n")
    |> Phoenix.HTML.raw()
  end
end
