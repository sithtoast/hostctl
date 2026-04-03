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

  In a deployed release the full version tag (e.g. "v0.1.0-α+build.2") is
  written to priv/VERSION at build time. That file is preferred over the OTP
  application version (which only carries the bare semver from mix.exs).
  """
  def current_version do
    # /etc/hostctl/version is written by the update/install script at deploy
    # time and is always up to date with the full tag (e.g. v0.1.0-α+build.3).
    # Fall back to the version packaged into the release priv dir, then to
    # the bare semver from mix.exs (dev environment).
    fixed_path = "/etc/hostctl/version"
    priv_path = Application.app_dir(:hostctl, "priv/VERSION")

    Enum.find_value([fixed_path, priv_path], fn path ->
      case File.read(path) do
        {:ok, contents} -> contents |> String.trim() |> strip_v_prefix()
        {:error, _} -> nil
      end
    end) || Application.spec(:hostctl, :vsn) |> to_string()
  end

  @doc """
  Returns the configured git branch. Defaults to `"main"`.
  """
  def current_branch do
    System.get_env("HOSTCTL_BRANCH", "main")
  end

  @doc """
  Returns the current commit SHA, or `nil` if unavailable.

  Reads from `/etc/hostctl/commit` (written by the deploy/update scripts),
  then `priv/COMMIT`, then falls back to `git rev-parse HEAD` in dev.
  """
  def current_commit do
    fixed_path = "/etc/hostctl/commit"
    priv_path = Application.app_dir(:hostctl, "priv/COMMIT")

    Enum.find_value([fixed_path, priv_path], fn path ->
      case File.read(path) do
        {:ok, contents} ->
          sha = String.trim(contents)
          if sha != "", do: sha

        {:error, _} ->
          nil
      end
    end) || git_head_sha()
  end

  defp git_head_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
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
  def check_for_updates(opts \\ []) do
    case Application.get_env(:hostctl, :github_repo) do
      nil ->
        {:error, :not_configured}

      repo ->
        branch = current_branch()

        if branch == "main" do
          do_check(repo, Keyword.get(opts, :prereleases, prereleases_enabled?()))
        else
          do_check_branch(repo, branch)
        end
    end
  end

  @doc """
  Returns whether update checks should include pre-releases by default.
  """
  def prereleases_enabled? do
    Application.get_env(:hostctl, :github_prereleases, false)
  end

  defp do_check(repo, prereleases?) do
    case fetch_latest_release(repo, prereleases?) do
      {:ok, release} ->
        current = current_version()
        latest = strip_v_prefix(release["tag_name"] || "")

        {:ok,
         %{
           mode: :release,
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

  defp do_check_branch(repo, branch) do
    commit = current_commit()

    if is_nil(commit) do
      {:error, :no_commit_info}
    else
      case fetch_branch_comparison(repo, commit, branch) do
        {:ok, comparison} ->
          ahead_by = comparison["ahead_by"] || 0

          commits =
            (comparison["commits"] || [])
            |> Enum.take(20)
            |> Enum.map(fn c ->
              %{
                sha: String.slice(c["sha"] || "", 0, 8),
                message:
                  c["commit"]["message"] |> to_string() |> String.split("\n", parts: 2) |> hd()
              }
            end)

          remote_sha =
            case comparison["commits"] do
              [_ | _] = list -> list |> List.last() |> Map.get("sha", "") |> String.slice(0, 8)
              _ -> String.slice(commit, 0, 8)
            end

          {:ok,
           %{
             mode: :branch,
             branch: branch,
             has_update: ahead_by > 0,
             current: String.slice(commit, 0, 8),
             latest: remote_sha,
             behind_by: ahead_by,
             commits: commits
           }}

        {:error, reason} ->
          {:error, reason}
      end
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
        release =
          Enum.max_by(releases, fn r -> parse_semver(strip_v_prefix(r["tag_name"] || "")) end)

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

  defp fetch_branch_comparison(repo, base_sha, branch) do
    url = "#{@github_api}/repos/#{repo}/compare/#{base_sha}...#{branch}"

    case Req.get(url,
           headers: [
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"}
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :commit_not_found}

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
  # Build metadata (+build.N) is NOT ignored here — the build number is
  # extracted and used as a tiebreaker so that e.g. v0.2.1-α+build.11 sorts
  # above v0.2.1-α+build.10. Any non-numeric build suffix appends 0.
  #
  # Pre-release suffixes (-alpha, -α, etc.) cause a -1 sentinel to be
  # inserted before the build number so that pre-releases of the same base
  # sort below their stable counterpart:
  #   [0,2,1,-1,11] < [0,2,1,0,0]  (pre-release < stable)
  #   [0,2,1,-1,10] < [0,2,1,-1,11] (older build < newer build)
  defp parse_semver(version) do
    # 1. Split off build metadata and extract trailing integer if present
    {version, build_num} =
      case String.split(version, "+", parts: 2) do
        [base, meta] ->
          num =
            meta
            |> String.split(".")
            |> List.last()
            |> then(fn s ->
              case Integer.parse(s || "") do
                {n, _} -> n
                :error -> 0
              end
            end)

          {base, num}

        [base] ->
          {base, 0}
      end

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

    # 4. Append release-type sentinel then build number
    release_sentinel = if prerelease?, do: -1, else: 0
    segments ++ [release_sentinel, build_num]
  end
end
