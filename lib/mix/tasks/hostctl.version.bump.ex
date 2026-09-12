defmodule Mix.Tasks.Hostctl.Version.Bump do
  use Mix.Task

  @shortdoc "Bump the source version and move Unreleased changelog notes together"
  @moduledoc """
  Run `mix hostctl.version.bump patch|minor|major` from the project root after
  adding notes under `## Unreleased` in CHANGELOG.md.

  Updates mix.exs and CHANGELOG.md locally. Does not start the application,
  assign a build number, commit, tag, push, or publish a release.
  """

  @version_pattern ~r/\bversion: "(\d+\.\d+\.\d+)"/
  @notes_pattern ~r/\A(.*?^## Unreleased\r?\n)(.*?)(?=^## |\z)(.*)\z/ms

  @impl Mix.Task
  def run([kind]) when kind in ["patch", "minor", "major"] do
    project = File.read!("mix.exs")
    changelog = File.read!("CHANGELOG.md")

    version =
      case Regex.scan(@version_pattern, project) do
        [[_, version]] -> version
        _ -> Mix.raise("Expected exactly one literal version in mix.exs")
      end

    next = next_version(version, kind)

    {prefix, notes, history} =
      case Regex.run(@notes_pattern, changelog) do
        [_, prefix, notes, history] -> {prefix, String.trim(notes), history}
        _ -> Mix.raise("CHANGELOG.md must contain a ## Unreleased section")
      end

    unless Regex.match?(~r/^[-*] \S/m, notes) do
      Mix.raise("Add changelog bullet points under ## Unreleased before bumping the version")
    end

    if Regex.match?(~r/^## #{Regex.escape(next)}(?:\s|$)/m, changelog) do
      Mix.raise("CHANGELOG.md already contains version #{next}")
    end

    updated_project = Regex.replace(@version_pattern, project, "version: \"#{next}\"")
    updated_changelog = prefix <> "\n## #{next}\n\n" <> notes <> "\n\n" <> history

    # Validate both inputs before modifying either tracked file.
    File.write!("mix.exs", updated_project)
    File.write!("CHANGELOG.md", updated_changelog)
    Mix.shell().info("Prepared #{version} → #{next}. Review the diff, then run mix precommit.")
  end

  def run(_), do: Mix.raise("Usage: mix hostctl.version.bump patch|minor|major")

  defp next_version(version, kind) do
    %Version{major: major, minor: minor, patch: patch} = Version.parse!(version)

    case kind do
      "patch" -> "#{major}.#{minor}.#{patch + 1}"
      "minor" -> "#{major}.#{minor + 1}.0"
      "major" -> "#{major + 1}.0.0"
    end
  end
end
