# Solid build and dependency security follow-up

September 12, 2026. This supersedes the failed `affd986` build launcher.

## Build failure

The operator's log failed at esbuild while importing `phoenix-colocated/hostctl`.
The launcher called `assets.deploy` before compiling Hostctl in a fresh checkout,
so LiveView had not generated the colocated-hook JavaScript. Tailwind succeeded;
esbuild could not resolve the generated package. The script failed before stopping
the installed panel or swapping releases. Read-only SSH confirmed that Hostctl,
Nginx, vsftpd and PHP 8.5 remained active.

`assets.deploy` now begins with `compile`, like `assets.build`. The packaged
updater and deployment instructions also compile before bundling. Validate this
with a fresh build directory; a cached Hostctl compilation hides the original bug.

## Dependency changes

The pasted log reported 35 unique CVEs across 11 packages. The updated lockfile
contains these replacements:

| Package | Previous | Updated |
| --- | --- | --- |
| Bandit | 1.10.4 | 1.12.5 |
| Decimal | 2.3.0 | 3.1.1 |
| Earmark | 1.4.48 | Removed; MDEx 0.13.5 / mdex_native 0.2.8 |
| HPAX | 1.0.3 | 1.0.4 |
| Mint | 1.7.1 | 1.10.0 |
| Phoenix | 1.8.5 | 1.8.13 |
| LiveView | 1.1.28 | 1.1.33 |
| Plug | 1.19.1 | 1.20.3 |
| Postgrex | 0.22.0 | 0.22.4 |
| Req | 0.5.17 | 0.7.4 |
| Swoosh | 1.24.0 | 1.28.0 |

Decimal's fix requires version 3. Ecto 3.14.2, ecto_sql 3.14.0 and MyXQL 0.9.0
allow that upgrade without overriding incompatible dependency requirements.
Related transitive updates are recorded in `mix.lock`.

Earmark is retired and has no patched release. Release notes now use
`HostctlWeb.Markdown`, which omits raw HTML and explicitly sanitizes rendered
Markdown before marking it safe. Basic headings, lists, emphasis, code, tables
and automatic links remain supported. Regression tests check normal Markdown
and reject script tags, event attributes and dangerous URL schemes.

Solid exposes a QEMU CPU without AVX/FMA. The default mdex_native Linux binary
crashed with an illegal instruction during the isolated build. Hostctl explicitly
selects the library's `use_legacy_artifacts: true` portable binary at compile time.
Release bundles built on newer CPUs must retain this setting for VM portability.

Official sources checked:

- [Earmark retirement and XSS advisory](https://cna.erlef.org/cves/CVE-2026-48591.html)
- [Decimal affected versions and fix](https://cna.erlef.org/cves/CVE-2026-32686.html)
- [MDEx rendering and sanitization](https://mdex.hexdocs.pm/MDEx.html)
- Package release metadata and advisories from the official Hex registry.

## Validation and deployment boundary

`mix hex.audit` reports no retired or security advisory packages in the updated
lockfile, without suppressions. This checks currently published Hex advisories;
it is not a complete security assessment of Hostctl, native libraries or the OS.
`mix precommit` passes all 291 tests, including the new Markdown tests and the
existing database, account isolation, resource attribution and Cloudflare tests.
The existing background orphan-upload task still emits a SQL Sandbox disconnect
during local test startup; it does not fail the suite.

A fresh, unprivileged production build on Solid passed `assets.setup`,
`assets.deploy` (including generation of colocated hooks before minification),
warnings-as-errors compilation and `mix release`. Build evidence is in
`/tmp/hostctl-security-build-xvUPb3YE/portable-build.log` on the VM. A release
`eval` using disposable runtime settings also verified the packaged dependency
versions and sanitized Markdown output, without starting Hostctl or connecting
to its database. The four installed services were still active afterward.

The follow-up does not need a database migration. A replacement pinned launcher
builds and audits before stopping Hostctl, keeps the previous release for rollback,
and verifies the running commit, resource snapshot and pure SRV payloads after
restart. The operator must run that launcher with interactive sudo. Do not use the
normal updater until published source includes these unpublished local commits.
Public Cloudflare writes and live MySQL operations remain untested by this work.
