# Versions and changelog

Use one source version for a completed feature or fix, rather than bumping for
each edit. `mix.exs` holds the source version; `CHANGELOG.md` holds human-written
notes. GitHub assigns the build number separately.

## Prepare a version locally

1. Add concise bullet points under `## Unreleased` in `CHANGELOG.md`.
2. Run one command from the repository root:

   ```sh
   mix hostctl.version.bump patch  # fix: 0.14.0 -> 0.14.1
   mix hostctl.version.bump minor  # feature: 0.14.0 -> 0.15.0
   mix hostctl.version.bump major  # breaking release: 0.14.0 -> 1.0.0
   ```

   Choose one. The command updates `mix.exs` and moves Unreleased notes under the
   new version, leaving an empty Unreleased section for subsequent work. It rejects
   empty notes and duplicate version headings. Run it once when the work is ready;
   further edits to that feature can update its existing notes.
3. Review the diff, run `mix precommit`, and commit the source and changelog together.

The command only edits local files. It does not start the application, run migrations,
assign build numbers, commit, push, tag or publish anything. A changelog version
heading records prepared source changes, not proof of a published release.

## Existing GitHub automation

`.github/workflows/tag-release.yml` runs on pushes to `main`. It reads the version
from `mix.exs`, reads `RELEASE_STAGE` (currently `α`), and tags the pushed commit as
`v0.14.0-α+build.N`. `N` is GitHub's workflow run number: it increments on a new
run, but not a retry. No build counter needs to be edited in the repository.

The workflow creates a **draft prerelease** with GitHub-generated notes. Review the
draft and include the relevant human-written changelog notes before publication.
It does not build a release artifact or deploy the application. Its existing tag
creation is not retry-safe if the same tag already exists.

This change preserves that workflow and its build numbering. Source versions can
stay the same across successive builds while a feature is being refined.

## Optional next step

[Release Please](https://github.com/googleapis/release-please) can maintain a release
PR with version and changelog changes from conventional commit messages such as
`feat:` and `fix:`. That requires adopting those commit conventions and adapting
the current draft-release workflow so the two systems do not compete over tags.
It is not configured here; the local command works with existing commit messages.

Reference: [GitHub run number and retry semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/variables).
