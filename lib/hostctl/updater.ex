defmodule Hostctl.Updater do
  @moduledoc """
  Checks for application updates via the GitHub Releases API.

  Configure the GitHub repository in your config:

      config :hostctl, :github_repo, "your-org/hostctl"
  """

  @github_api "https://api.github.com"

  @doc """
  Returns the current application version string.
  """
  def current_version do
    Application.spec(:hostctl, :vsn) |> to_string()
  end

  @doc """
  Fetches the latest release from GitHub and compares with the current version.

  Returns `{:ok, info}` where `info` is a map with:
    - `:current` — the running version string
    - `:latest`  — the latest published version string
    - `:has_update` — boolean, true when latest is newer than current
    - `:release`    — release metadata map (tag, name, body, url, published_at)

  Returns `{:error, reason}` on failure.
  """
  def check_for_updates do
    case Application.get_env(:hostctl, :github_repo) do
      nil -> {:error, :not_configured}
      repo -> do_check(repo)
    end
  end

  defp do_check(repo) do
    case fetch_latest_release(repo) do
      {:ok, release} ->
        current = current_version()
        latest = strip_v_prefix(release["tag_name"] || "")

        {:ok,
         %{
           current: current,
           latest: latest,
           has_update: version_newer?(latest, current),
           release: %{
             tag: release["tag_name"],
             name: release["name"] || release["tag_name"],
             body: release["body"],
             html_url: release["html_url"],
             published_at: release["published_at"]
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private helpers ---

  defp fetch_latest_release(repo) do
    url = "#{@github_api}/repos/#{repo}/releases/latest"

    case Req.get(url,
           headers: [
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"}
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :no_releases}

      {:ok, %{status: 403}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp strip_v_prefix("v" <> version), do: version
  defp strip_v_prefix(version), do: version

  # Returns true when version string `a` is strictly newer than `b`.
  defp version_newer?(a, b) do
    parse_semver(a) > parse_semver(b)
  end

  defp parse_semver(version) do
    version
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, _} -> n
        :error -> 0
      end
    end)
  end
end
