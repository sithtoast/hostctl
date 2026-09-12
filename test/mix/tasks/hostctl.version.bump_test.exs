defmodule Mix.Tasks.Hostctl.Version.BumpTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Hostctl.Version.Bump

  setup do
    dir = Path.join(System.tmp_dir!(), "hostctl-version-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "[app: :hostctl, version: \"0.14.7\"]\n")

    File.write!(
      Path.join(dir, "CHANGELOG.md"),
      "# Changelog\n\n## Unreleased\n\n### Added\n\n- New feature.\n\n## 0.14.7\n\n- Earlier change.\n"
    )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  for {kind, expected} <- [{"patch", "0.14.8"}, {"minor", "0.15.0"}, {"major", "1.0.0"}] do
    test "#{kind} updates both files and preserves history", %{dir: dir} do
      File.cd!(dir, fn ->
        Bump.run([unquote(kind)])
        assert File.read!("mix.exs") == "[app: :hostctl, version: \"#{unquote(expected)}\"]\n"

        assert File.read!("CHANGELOG.md") ==
                 "# Changelog\n\n## Unreleased\n\n## #{unquote(expected)}\n\n### Added\n\n- New feature.\n\n## 0.14.7\n\n- Earlier change.\n"

        assert_raise Mix.Error, ~r/Add changelog bullet points/, fn ->
          Bump.run([unquote(kind)])
        end

        assert File.read!("mix.exs") == "[app: :hostctl, version: \"#{unquote(expected)}\"]\n"
      end)
    end
  end

  test "invalid notes, duplicate versions and missing version do not modify either file", %{
    dir: dir
  } do
    File.cd!(dir, fn ->
      project = File.read!("mix.exs")

      for changelog <- [
            "# Changelog\n",
            "## Unreleased\n\n### Added\n",
            "## Unreleased\n\n- New.\n\n## 0.14.8\n\n- Already prepared.\n"
          ] do
        File.write!("CHANGELOG.md", changelog)
        assert_raise Mix.Error, fn -> Bump.run(["patch"]) end
        assert File.read!("mix.exs") == project
        assert File.read!("CHANGELOG.md") == changelog
      end

      File.write!("mix.exs", "[app: :hostctl]\n")
      assert_raise Mix.Error, ~r/exactly one literal version/, fn -> Bump.run(["patch"]) end
      assert File.read!("mix.exs") == "[app: :hostctl]\n"
    end)
  end

  test "invalid arguments do not modify files", %{dir: dir} do
    File.cd!(dir, fn ->
      project = File.read!("mix.exs")
      changelog = File.read!("CHANGELOG.md")
      assert_raise Mix.Error, ~r/Usage:/, fn -> Bump.run(["build"]) end
      assert File.read!("mix.exs") == project
      assert File.read!("CHANGELOG.md") == changelog
    end)
  end
end
