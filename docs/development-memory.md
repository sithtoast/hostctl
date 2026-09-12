# Development environment memory

## Current Ubuntu 26.04 isolation trial (September 12, 2026)

- Remote server: `william@192.211.55.181`, hostname `hostctl-dev`, Ubuntu 26.04
  x86_64. This is a different machine from the historical local VM below.
- Dedicated SSH key: `/Users/wmh/.ssh/hostctl_ubuntu26_agent`. Use this explicit
  key with `IdentitiesOnly=yes`; the old `hostctl-dev` SSH alias targets the old VM.
- SSH and active `hostctl`, Nginx, vsftpd and PHP 8.5 services were rechecked today.
  Sudo still requires interactive authentication.
- Panel: `https://solid.toastedlabs.com`. Installed release `/opt/hostctl`, source
  `/usr/local/src/hostctl`, environment `/etc/hostctl/env`. Never print the env file
  or FTP test credential state. The server was restored to its pre-install snapshot
  and installed from the local `338aa16` bundle without incremental repairs.
  Installed HEAD and active services were independently rechecked after installation.
- Operator reports both the PHP/filesystem smoke test and FTP preparation passed
  on the clean install, then reports the Plesk import looks good. The final clean
  install's post-reboot `verify` output was not supplied; the earlier repaired trial
  did pass that step with an explicitly changed boot ID and successful cleanup.
- `crohnies.org` now has a root-owned domain boundary with group `hc_5` and ACLs,
  per the operator's directory listing. Cloudflare was enabled manually after import.
- Read-only live logs identified three rejected SRV records (`_imaps._tcp`,
  `_pop3s._tcp`, `_smtps._tcp`): "weight is a required data field." An apex NS
  push failed with "An identical record already exists." The separate follow-up
  fixes structured SRV payloads and conservative full-value matching locally;
  see [Cloudflare follow-up](cloudflare-sync-follow-up.md) for behavior, official
  sources, validation limits and proposed deployment/test steps. It is not deployed.
  The follow-up independently rechecked source `338aa16` and all four active
  services over the explicit SSH key. No public DNS was changed.
- System username changes are a separate design question. The helper enforces
  `hc_<owner_id>`; names also appear in reservations, boundary markers, PHP pools,
  sockets, private directories and FTP configuration. A friendly label is simpler;
  actual renaming requires a managed migration preserving numeric UID/GID. No
  rename has been selected or implemented. The user selected a resource view plus
  shell PID/UID/username lookup for rapid process attribution. That read-only option
  is now implemented locally; see [Account resources](account-resources.md).
  Recognizable names can be revisited with future SSH access. Do not manually
  rename live accounts.
- The user requested merging the isolation work into the default branch (called
  `main` in this repository, not `master`) and continuing these issues in another task.
- No GitHub push has occurred in this task. Use the locally prepared bundle for
  the fresh trial unless a push is explicitly authorized.

## Historical local VM notes

Last verified for the older local VM: 2026-09-05 (America/New_York).

## Working VM and access

- Parallels Ubuntu VM, hostname `hostctl-vm`, user `william`, static IP
  `10.0.221.34`. Earlier addresses in the conversation are obsolete.
- Mac SSH alias: `hostctl-dev`. Use `ssh -o BatchMode=yes hostctl-dev`.
- The alias in `/Users/wmh/.ssh/config` selects the dedicated key
  `/Users/wmh/.ssh/hostctl_dev_agent`, with `IdentitiesOnly yes` and keepalives.
  Its public key is installed on the VM. Never copy private key material into
  the repository or VM.
- SSH works from Codex after enabling macOS **Privacy & Security → Local
  Network → Codex**. Before this, Codex reported “No route to host” while the
  same connection worked from Terminal. Check app-specific access before
  recommending more VM network changes if this difference returns.
- The user uses bridged Wi-Fi and reported connectivity working after assigning
  static IPs to the Mac and VM. Parallels Wi-Fi bridging may share the host MAC
  and confuse UniFi client identity. Current SSH connectivity is verified;
  long-term network stability has not been established.
- `william` can SSH with the key but sudo requires the user's password. Root
  installation/service operations need the user to run the supplied command.
  Do not assume passwordless sudo has been configured.

## Daily development loop

- Local source: `/Users/wmh/Dev/hostctl`.
- VM development source: `/var/lib/hostctl/dev`.
- From the Mac repository: `bash scripts/vm-sync hostctl-dev`.
  Preview with `bash scripts/vm-sync hostctl-dev --dry-run`.
- Local source is authoritative. Sync includes uncommitted edits and deletes
  removed source files in the dedicated VM checkout, while excluding VM build
  caches, dependencies, `.env*`, generated assets, and other listed artifacts.
- `hostctl-dev.service` runs Phoenix from source with `MIX_ENV=dev` and
  `HOSTCTL_VM_DEV=1`; the packaged `hostctl.service` is stopped while it runs.
- Panel hostname: `https://dev-panel.toastedlabs.com`. Nginx proxies to Phoenix
  on `127.0.0.1:4000`. The installation uses Cloudflare mode: the panel origin
  is HTTP-only and rejects raw-IP Host headers. Private-network access by the
  correct hostname is a separate issue from origin HTTPS configuration.
- Read status/logs with `systemctl status hostctl-dev --no-pager` and
  `journalctl -u hostctl-dev -f` on the VM.
- After config/supervision changes, the user can run, on the VM:
  `sudo bash /var/lib/hostctl/dev/scripts/vm-dev start`.
- Return to the packaged release with:
  `sudo bash /var/lib/hostctl/dev/scripts/vm-dev release`.
  This switches processes; it does not roll back database migrations or Nginx
  changes. Take a VM snapshot before destructive hosting/import experiments.

## Verified setup and gotchas

- Development service is active/running with zero restarts at last check.
  Login page returned HTTP 200 through Nginx; unauthenticated `/` returned the
  expected 302. Migrations were already current during bootstrap.
- **inotify-tools is installed** (`/usr/bin/inotifywait`), and the user restarted
  `hostctl-dev`. The latest startup no longer reports the missing file-system
  watcher. `scripts/vm-dev setup` now installs this dependency when absent.
  Actual browser auto-refresh still needs an end-to-end check.
- VM uses Elixir 1.18.3/OTP 27. Mac uses Elixir 1.20.3. Avoid regex modifier `E`;
  the dev watcher patterns now use `\z` for strict end-of-string matching and
  compile on the VM. All four VM configuration tests passed there.
- VM mode reuses installed credentials and encryption key from
  `/etc/hostctl/env`; don't expose its contents in logs or responses.
- VM certificate issuance uses Let's Encrypt staging and
  `/var/lib/hostctl/letsencrypt-staging`. Staging certificates are untrusted by
  browsers. Automatic scheduled backups are disabled in VM mode.
- `mix precommit` on the Mac remains blocked by existing Elixir 1.20 compiler
  warnings in unrelated modules. Do not report full precommit as passing.
- Dependency fetching reported multiple security advisories and retired
  Earmark. Those are unresolved; bootstrap success does not establish security
  readiness for production.

## Outstanding work

- Verify browser reloads and the HTTP/HTTPS matrix for local files, S3 paths,
  subdomains, and Docker proxy endpoints; then recheck Plesk imports.
- The HTTP/HTTPS toggle is currently domain-wide, not per path/subdomain.
- Certificate activation's `unless domain.ssl_enabled or domain.allow_http_with_ssl`
  condition in `Hostctl.Hosting` needs follow-up; it can skip enabling SSL when
  HTTP access was selected. This was identified, not fixed.
- User suggested an administrator-controlled temporary support/agent SSH-key
  access toggle. Discussed key expiry, permissions, revocation, and auditing;
  the product feature is not implemented.
- Installer supports saved-choice retries via `--resume`; see
  [installer-resume.md](installer-resume.md). Ubuntu 26.04 failed on the missing
  Erlang PPA suite; resume does not fix unsupported package sources.

See [vm-development.md](vm-development.md) for the reusable setup guide.

## Plesk S3 import fixes (September 5, 2026)

- Logs from the `toastednet.org` import showed four subdomain S3 jobs failing
  because `s3.wasabisys.com` lacked an HTTP scheme. The main domain's local rsync
  succeeded. Inline backend validation errors were silently discarded, and
  upload prefixes included the target directory while saved serving prefixes
  did not. Saved migration configs also omitted all S3 destination choices.
- Local changes normalize bare endpoints to HTTPS, validate enabled destinations,
  persist mappings in the importer task, share exact upload/serving prefixes, and
  preserve encrypted S3 choices when saving migrations. Retrying old jobs also
  normalizes their endpoint. Background transfers have their own status; finishing
  the import task does not mean all uploads completed.
- Import preflight installs FTP, mail, database and rclone components as needed
  before domain creation. It waits for setup and stops on failure. Existing
  MariaDB packages take precedence over installing conflicting MySQL packages.
- Saved S3 connections are per panel user, encrypt secrets, and require migration
  `20260906011749_create_s3_connections`. The importer has a connection selector,
  bucket listing and explicit bucket creation. No new routes: existing admin-only
  Plesk Import LiveView.
- Development SQL logs exposed credential parameters. VM config now uses Repo
  `log: false` and Logger `:info`; this requires a service restart. Do not copy
  raw SQL/LiveView parameter logs into diagnostics. Credentials should be rotated.
- Deployment and repair of existing `toastednet.org` mappings/jobs are still
  pending: SSH to `10.0.221.34` repeatedly timed out, including after the user
  reported the VM back up. Do not claim the changes are live until verified.

### Update staged on the VM

- SSH recovered. Read-only DB checks confirmed four jobs (IDs 1–4) still marked
  running, all four malformed endpoints, and zero S3 backends for toastednet.org.
  FTP, MariaDB and rclone are currently recorded as installed.
- Full local suite: **177 tests passed**. `mix precommit` is still blocked by
  pre-existing Elixir 1.20 unreachable-clause/unused-require warnings outside
  the importer. `git diff --check` passed.
- Tested source and a bounded repair launcher are staged at
  `/tmp/hostctl-import-fix-20260905` on the VM. The active checkout is unchanged.
- The VM requires william's interactive sudo password. Next user command:
  `sudo bash /tmp/hostctl-import-fix-20260905/apply`.
- The launcher stops dev, copies staged source, runs migrations, reconstructs
  only the deko/dk/hexenworld/kmq2 bucket mappings from recorded jobs, normalizes
  those endpoints, marks interrupted jobs paused, checks Nginx and restarts dev.
  It preserves existing mappings and completed jobs and does not start uploads.
  Resume the four paused jobs from Plesk Import afterward.
- Old FTP mount / directory listing choices were not recorded in the jobs;
  recovered mappings leave both off. Enable those separately if desired.
- Verify the root command, mappings, resumed jobs and live bucket controls after
  the user runs it. Do not claim the patch is installed before then.

## Cloudflare follow-up local validation (September 12, 2026)

- `mix precommit`: 277 tests passed, including Cloudflare HTTP stubs and matching
  regressions; warnings-as-errors compilation and formatting passed. The historical
  compiler-warning blocker above did not reproduce in this worktree.
- The suite logged a background orphan-upload cleanup SQL sandbox disconnect
  during startup; no tests failed. No deployment or live DNS acceptance occurred.
- Prepared rollout and recovery steps are in `docs/cloudflare-sync-follow-up.md`.

## Account resource follow-up (September 12, 2026)

- User chose the operational resource view plus shell lookup; Linux names remain
  stable. `/panel/resources` is admin-only, with read-only PID/UID/username lookup
  through `bin/account-owner` or `mix hostctl.account.owner`.
- Final `mix precommit`: 289 tests passed. Assets and shell syntax checks passed.
  Browser verification used an isolated local server and synthetic processes.
  The actual Mix lookup passed against that disposable database; the Linux parser
  read 204 real processes from the Ubuntu test server. Installed-service process
  visibility and attribution still need post-deployment verification.
- No deployment, public DNS mutation, GitHub push, identity rename or SSH enablement
  occurred. See `docs/account-resources.md` for metric limits and acceptance steps.
