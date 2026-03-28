defmodule Hostctl.Updater do
  @moduledoc """
  Checks for application updates via the GitHub Releases API.

  Configure the GitHub repository in your config:

      config :hostctl, :github_repo, "your-org/hostctl"

  To also include pre-releases:

      config :hostctl, :github_prereleases, true
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
    prereleases? = Application.get_env(:hostctl, :github_prereleases, false)

    case fetch_latest_release(repo, prereleases?) do
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
             published_at: release["published_at"],
             prerelease: release["prerelease"] == true
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private helpers ---

  defp fetch_latest_release(repo, _prereleases? = false) do
    url = "#{@github_api}/repos/#{repo}/releases/latest"
    get_release(url)
  end

  # When prereleases are included, fetch a page of releases and pick the most recently
  # *published* one. GitHub sorts the list by created_at (when the release record was
  # first saved, possibly as a draft), so per_page=1 can return a stale stable release
  # instead of a freshly-published pre-release. Sorting client-side by published_at fixes this.
  defp fetch_latest_release(repo, _prereleases? = true) do
    url = "#{@github_api}/repos/#{repo}/releases?per_page=10"

    case Req.get(url,
           headers: [
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"}
           ]
         ) do
      {:ok, %{status: 200, body: [_ | _] = releases}} ->
        release = Enum.max_by(releases, fn r -> parse_semver(strip_v_prefix(r["tag_name"] || "")) end)
        {:ok, release}

      {:ok, %{status: 200, body: []}} ->
        {:error, :no_releases}

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

  defp get_release(url) do
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

  @doc """
  Returns the path to the update script.

  Configurable via the `HOSTCTL_UPDATE_SCRIPT` environment variable.
  Defaults to `/opt/hostctl/bin/update`.
  """
  def update_script_path do
    System.get_env("HOSTCTL_UPDATE_SCRIPT", "/opt/hostctl/bin/update")
  end

  @doc """
  Returns `true` when the update script exists on disk.

  Used to decide whether to show the "Update now" button in the UI.
  """
  def update_possible? do
    File.exists?(update_script_path())
  end

  defp strip_v_prefix("v" <> version), do: version
  defp strip_v_prefix(version), do: version

  # Returns true when version string `a` is strictly newer than `b`.
  defp version_newer?(a, b) do
    parse_semver(a) > parse_semver(b)
  end

  # Parses a semver string into a comparable list of integers.
  #
  # Build metadata (+build.N) is ignored per semver. Pre-release suffixes
  # (-alpha, -α, etc.) cause a -1 to be appended so that pre-releases sort
  # below their stable counterpart, e.g. [0,0,1,-1] < [0,0,1,0].
  defp parse_semver(version) do
    # 1. Drop build metadata
    [version | _] = String.split(version, "+")

    # 2. Split base from optional pre-release identifier
    {base, prerelease?} =
      case String.split(version, "-", parts: 2) do
        [base, _pre] -> {base, true}
        [base] -> {base, false}
      end

    # 3. Parse the numeric base segments
    segments =
      base
      |> String.split(".")
      |> Enum.map(fn part ->
        case Integer.parse(part) do
          {n, _} -> n
          :error -> 0
        end
      end)

    # 4. Append release-type sentinel: -1 for pre-releases, 0 for stable
    if prerelease?, do: segments ++ [-1], else: segments ++ [0]
  end
end
