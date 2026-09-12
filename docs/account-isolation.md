# Per-account system identities

Implementation and roadmap, updated September 12, 2026. Identity reservations,
database preflight, and Linux enrollment for empty owners are implemented. Plesk
imports automatically enroll new or matching empty owners, including an admin
account. Owners with existing hosting resources retain their legacy runtime until
a separate migration.

## First implementation milestone

`Hostctl.Isolation` provides scoped, idempotent identity reservations and a
database inventory. Apply migration `20260909102735_create_account_system_identities`
to the intended database before using these commands:

```sh
mix hostctl.isolation.plan --user-id 123
mix hostctl.isolation.plan --user-id 123 --reserve
```

The default command reads database inventory and prints JSON. `--reserve` writes
a pending reservation for an owner with domains or FTP accounts. It does not
create a Linux user or alter live services. Names derive from the hosting owner's
stable database ID, and reservations survive deletion of that panel user. The
database enforces unique names, original owners and assigned numeric IDs, and
rejects root IDs or ready states without both UID and GID. Reservations are
serialized using the owner's row lock.

The command starts only the repository, so inspecting the inventory does not
start Hostctl's web, backup or upload workers. It does not run migrations itself.
Use the intended deployment environment's normal configuration and database
credentials. This is an operator command, not a new web route.

The report identifies custom or unsupported document roots, cross-account path
overlap, FTP mappings outside the owner's domain trees, unsafe/duplicate mount
names, S3 mounts, unfinished uploads and enabled cron records. It excludes
credentials, cron commands, upload metadata and other owners' inventory. Invalid
foreign paths generate a generic blocker because their overlap cannot be ruled
out. Findings use `blocker` for known conflicts and `review` for resources that
need additional migration handling.

This is a point-in-time database inventory with lexical path checks. It does not
inspect the Linux filesystem, lock out writers, detect live backup/restore work,
or establish that migration is safe. `apply_supported` is always false. Even a
report with no findings requires the listed live checks; there is no apply mode.

Reservations alone do not activate isolation. Use the enrollment command below
before adding hosting resources. Resumable conversion of existing accounts is
the next milestone.

## Linux enrollment and runtime

On the Linux host, with the intended environment configured and the database
migrated, enroll an empty panel account:

```sh
mix hostctl.isolation.provision --user-id 123
```

The command requires the normal Hostctl `sudo systemd-run` capability, Python 3,
`acl`, Nginx, and the desired PHP-FPM versions. The installer includes Python and
ACL tools. The command starts only the repository. No new routes or LiveViews
are added; normal authenticated domain and FTP management remains in place.

Enrollment does the following:

- Creates a locked `hc_<owner_id>` Linux user and private group, verifies their
  login policy and numeric IDs, and records readiness. Existing unrelated users
  or groups are rejected. Root-owned records under `/var/lib/hostctl-isolation`
  contain random ownership markers so retries can recognize partial provisioning.
- Separates Nginx into the locked `hostctl-web` identity. Its supplementary
  `www-data` group preserves access to legacy PHP sockets. New account ACLs and
  sockets grant access to the named web identity, not to legacy PHP's `www-data`
  identity. Nginx config is validated before reload; the initial config is saved
  at `/var/lib/hostctl-isolation/nginx-before-isolation.conf`.
- Applies an HTTP-wide `disable_symlinks if_not_owner` policy to stop legacy
  vhosts from exposing other accounts through symlinks. Isolated vhosts use the
  stricter `disable_symlinks on`. Existing symlink-dependent sites and custom
  Nginx worker configurations need review before enrollment.
- Creates canonical `/var/www/<domain>` boundaries owned by root with the
  tenant's private group, then account-owned document roots and inherited web
  reader ACLs. Directory operations use no-follow file descriptors. Existing
  unclaimed trees are rejected instead of recursively converted.
- Generates one PHP pool per account/version, with an account UID/GID and a
  socket accessible only to `hostctl-web`. Sessions and temporary files live
  under `/var/lib/hostctl-accounts/<username>` in private account-owned directories.
- Maps single-directory FTP accounts to the owner's Linux identity, with upload
  modes that preserve inherited read access and `SITE CHMOD` disabled. Normal
  FTP credentials remain virtual credentials; SSH/SFTP is not enabled.

Enrollment is serialized against the account's first domain/FTP creation. Failed
enrollment persists a failed state and blocks shared-runtime fallback. Retry the
same enrollment command after correcting the underlying issue. New domain/FTP
creation rolls back its database changes when service provisioning fails;
root-side identity/path claims remain available for retries. Nginx reload failure
restores an isolated vhost's previous on-disk configuration.

Once isolation is in use, legacy ownership maintenance uses a descriptor-based
helper that rejects symlinks, hard links, foreign owners and isolated boundaries.
The repair script preserves isolated FTP roots. Plesk local-file imports use
isolation-aware staging and copying. Other restore paths into known isolated
boundaries remain blocked pending dedicated migration work.

The supported initial flow is an empty owner, canonical new domain trees,
installed PHP versions and single-directory FTP. Existing hosted accounts,
custom document roots, and isolated FTP bind/FUSE mounts are rejected. S3 HTTP
proxy serving remains available without FTP mounts. Cron execution, container
identity integration, account-wide suspension, SSH/SFTP and ownership conversion
are not implemented by this milestone. Broad control-plane sudo access remains
a separate hardening task.

## Validation and VM rollout

Run `mix precommit` for Elixir checks. The disposable Linux test exercises actual
Nginx, PHP-FPM and vsftpd with two accounts, including PHP UIDs, static access,
sessions, FTP upload/rename/delete ownership, cross-account and legacy-PHP denial,
symlink denial, enrollment retries, OS collisions and protected legacy chown:

```sh
docker build -f test/isolation/Dockerfile -t hostctl-isolation-test:local .
docker run --rm hostctl-isolation-test:local
```

The Docker build context is restricted to the helper and smoke test. These tests
do not prove the VM's systemd reload behavior or its existing-site compatibility.
The smoke test refuses to run outside a disposable Docker container.

`scripts/vm-isolation-apply` applies a staged source checkout to the test VM,
backs up the previous source, installs Python/ACL prerequisites, migrates and
restarts `hostctl-dev`. It does not enroll any accounts or change Nginx's worker
identity. Enrollment occurs later through the operator CLI or an eligible Plesk import. Run the apply
script from the staged checkout as root; it refuses to run from the active one.

Container validation passed on Ubuntu 24.04 with PHP 8.3. The subsequent live
Ubuntu 26.04/PHP 8.5 trial passed enrollment, Plesk file import, PHP/FTP isolation,
and reboot persistence after the fixes described below. The subsequent clean
installation results and remaining verification boundary are recorded below.

## Ownership boundary

Each hosting account receives a dedicated, locked Linux user and private group.
Use a generated name such as `hc_123`, independent of editable email addresses,
display names, domain names, and imported Plesk logins. Persist the assigned
UID/GID and provisioning state; never silently adopt an existing OS identity or
reuse an identity that still owns retained files.

Today, domains and FTP accounts belong directly to `users`. Initially, that
owner is the hosting-account boundary. `managed_by_id` grants management access;
it must not merge a manager's customers into one Linux identity. Provision an
identity when an owner first needs hosting resources, rather than for every
panel-only login. Future team logins should reference the same hosting account.

Disable password and interactive shell login by default. FTP credentials remain
separate virtual credentials. SSH/SFTP enablement is a separate feature with
explicit key management and a root-owned chroot where applicable.

## Original migration scope

This table records the starting point; implemented portions are described above.

| Area | Original behavior | Target behavior |
| --- | --- | --- |
| Website files | `WebServer.provision_webroot/1` recursively assigns domain trees to `www-data` | Account-owned files; private account boundaries; narrowly scoped Nginx read/traverse access |
| PHP | `WebServer.Nginx` selects a shared PHP-version socket | Managed pool per account and PHP version, running as the account UID/GID; Nginx uses its socket |
| FTP | `FtpServer` uses shared ownership and global `guest_username=www-data` | Verified per-account identity mapping, account-scoped paths, restrictive upload defaults |
| S3 mounts | `RcloneMount` generates `--allow-other` mounts without explicit tenant UID/GID or permission checks | Explicit owner and permissions, isolated cache/credentials, kernel permission enforcement and tested Nginx/FTP access |
| Imports | Plesk transfer paths request `www-data:www-data` | Resolve the destination account identity and preserve isolation through transfer completion |
| Backups/restores | Multiple local and S3 restore paths | Restore into authorized account paths; map ownership to the destination identity, never blindly trust archive numeric IDs |
| Scheduled jobs | Hosting context persists domain cron records | Any OS job provisioning must run as the owner, with private working directories and environment |
| Installer/repair | Shared ownership and broad service privilege assumptions | Preserve account identities and permissions during install, repair, upgrades, and feature setup |

PHP pools need private session, temporary, upload, and log directories. Tenant
users must not join the shared web-server group. Nginx access should not grant
tenant processes access to other tenants. Shared Nginx also needs a symlink
policy so a customer cannot expose another customer's files through a symlink
that the Nginx worker can read. Secrets belong outside public document roots.

Custom document roots, FTP mount sources, and restore destinations require
account ownership checks, canonical containment checks, and rejection of path
traversal, configuration injection, and unexpected symlinks. Privileged file
operations must account for symlink races, hard links, and mount boundaries;
a string-prefix check followed by recursive root `chown` is insufficient.
Do not recursively change ownership through live bind or FUSE mounts.

Hostctl keeps its own service identity. Account processes must not inherit its
credentials, groups, or privileged command access. The existing unrestricted
`sudo systemd-run *` service grant is not a narrowly scoped privileged helper;
reducing control-plane privilege is a distinct hardening task and must not be
claimed as accomplished by assigning tenant UIDs.

## Provisioning and failure handling

Use explicit states such as pending, provisioning, ready, migrating, and failed.
Serialize work per account and make retries idempotent. Database transactions
cannot roll back OS user creation or service reloads: retain enough operation
state to reconcile partial failures.

Existing web and FTP provisioning is best-effort and callers can report success
after an OS failure. Isolated hosting must surface failure and prevent activation
until required identity, permissions, pools, and service configuration are ready.
Never fall back to a shared PHP pool or shared FTP identity after failure.

Domain transfer between owners is a migration of runtime identity, files, pools,
mounts, and jobs. Suspension must stop applicable runtime and transfer access,
not just change an HTTP page. Account deletion must distinguish retention from
purging; do not remove or recycle identities while retained data references them.

## Existing-account migration

1. Inventory account ownership, document roots, current modes/ACLs, hard links,
   symlinks, mounted filesystems, PHP versions, FTP mappings, imports, restores,
   and jobs. Report overlapping roots or cross-account mappings as blockers.
2. Produce a dry-run plan per account. Snapshot the VM and save configuration,
   file ownership/mode/ACL metadata, and migration state before applying it.
3. Quiesce writes for that account, including PHP, FTP, imports, restores, and
   scheduled work. Provision and verify the destination UID/GID.
4. Apply ownership and access policy only to validated local paths. Configure
   pools, FTP identity mapping, and mount permissions. Validate PHP and Nginx
   configuration before activating it.
5. Switch service configuration, resume access, and run positive and negative
   isolation checks. Mark ready only after these checks pass.
6. On failure, retain an explicit failed state and resume or restore saved
   configuration and metadata deliberately. Do not silently reopen shared access.

Routine startup, domain sync, or a database migration must not initiate a global
recursive ownership conversion. Existing accounts need explicit migration state;
do not describe an installation as fully isolated while legacy accounts remain.

## Acceptance checks

Use two disposable customer accounts on Linux with the actual service versions.
Verify each can serve static files and PHP, upload/rename/delete over FTP, and
use its configured S3 mount. Verify the PHP process UID/GID and selected socket.
Prove one account cannot read private files, write files, access private sockets,
or traverse FTP mappings belonging to the other. Check Nginx symlink behavior.

Repeat after domain sync, import, restore, feature repair, and restart. Include
failure recovery, concurrent provisioning, suspended accounts, custom roots,
multiple PHP versions, mounted subdirectories, and retained-data deletion.
Check ordinary HTTP/HTTPS, subdomains, and proxy routes remain functional.

Run focused unit/integration tests and `mix precommit`. Local macOS tests cannot
prove Linux UID isolation, vsftpd identity switching, FUSE enforcement, or live
PHP/Nginx behavior. Validate those on the test VM before production rollout.

### Fresh-install Plesk imports

The Plesk import page now automatically enrolls owners created by either **Create
account** or **Auto-create accounts** before assigning domains. Each owner gets
one Linux identity shared by that owner's domains, private PHP pools, and isolated
single-directory FTP accounts. When starting an import with an existing email
match, an empty account is enrolled too; its panel role and login remain unchanged.
Existing owners with domains or FTP accounts retain their current runtime.
Failed enrollment retains a blocked account; retrying the domain import retries
its enrollment before creating resources. The provisioning CLI also supports retry.

Local web-file imports use temporary staging followed by a guarded copy into the
owner's tree. Files receive the owner UID/GID and Nginx read ACLs. Existing files
are replaced without following destination symlinks. Source symlinks, hardlinks,
and special files are rejected; the import reports failure and can be retried
(files already copied are retained). Staging needs enough local disk space for
the selected source directory and is removed after the attempt.

For a fresh-install trial, install from `codex/account-isolation`, select local
web storage, auto-create owners, then import domains and web files. Verify two
owners receive different `hc_*` UIDs, PHP pools and FTP guest mappings, and that
one owner's PHP cannot read the other's files. Subscription FTP logins spanning
multiple domain roots still report unsupported bind mounts. S3 FTP mounts and
existing-account conversion remain unsupported; S3 HTTP proxy uploads are separate
from this local-files path. Cron import is still unavailable.

On a fresh supported Linux VM, fetch this branch and run its installer:

```bash
git clone --branch codex/account-isolation https://github.com/sithtoast/hostctl.git
cd hostctl
sudo bash priv/deploy/install.sh --interactive \
  --repo=https://github.com/sithtoast/hostctl.git \
  --branch=codex/account-isolation
```

Keep the branch argument: the installer's default is `main`. The disposable Linux
smoke test covers import-file ownership and service access, but does not substitute
for a complete fresh installation and a transfer from your Plesk server.

### Live isolation smoke check without public DNS

Run `sudo bash scripts/isolation-smoke` from a checkout containing both
`scripts/isolation-smoke` and `scripts/isolation-smoke.exs` on an installed server.
The wrapper assumes the standard `/opt/hostctl` release and `/etc/hostctl/env`.
It runs against the live application over release RPC; it does not restart the
panel. Domain provisioning briefly reloads Nginx and PHP-FPM using the normal
Hostctl path.

The check creates two new panel owners and random `hc-check-*.test` domains with
DNS templates disabled. Requests go to `127.0.0.1` with the test Host header. It
checks distinct PHP UIDs, static serving, same-owner reads/writes, cross-owner
read/write/create/list denial, private PHP session configuration, symlink denial
through Nginx, legacy `www-data` read denial, and peer PHP socket access denial.
No public DNS, Cloudflare access, real domain, or FTP password is required.

A `finally` cleanup removes the test domains, their files, and panel users. The
locked Linux identities, identity tombstones, private homes and PHP pool
configurations remain reserved under Hostctl's identity-retention policy. Each
run creates two such reservations. If cleanup fails, the script reports failure
and identifies the test domain/user needing attention. A killed server/process
can also require manual cleanup. The check never targets existing websites.

This exercises the installed provisioning and HTTP/PHP services; it does not
prove FTP protocol behavior, import fidelity, HTTPS, or reboot persistence.

### FTP protocol and reboot persistence check

The companion `scripts/ftp-isolation-smoke` uses the same loopback-only `.test`
strategy. Keep its `.exs` file and `ftp-isolation-probe.py` alongside the wrapper.
Run `sudo bash scripts/ftp-isolation-smoke prepare` on the installed server. It
creates two isolated owners, domains and FTP logins, and tests both directions:
FTP upload/overwrite/rename/delete, directory creation/removal, upload UID,
Nginx serving, PHP execution, chroot confinement and cross-owner path/symlink
read/write denial. It checks the installed FTP service on loopback port 21.
FTPS is used when AUTH TLS is supported; local certificate trust is outside the
scope of this test. No external FTP client or firewall traversal is tested.

Preparation preserves marker files and saves random test credentials in
`/var/lib/hostctl/ftp-isolation-check/state.json` (directory 0700, file 0600).
After a successful preparation, reboot at a convenient time. Run
`sudo bash scripts/ftp-isolation-smoke verify` after SSH returns. Verification
requires a changed kernel boot ID, checks the original database/UID mappings,
then authenticates with the original credentials and retrieves the original
files before testing operations again. It does not re-provision resources or
recreate missing marker files before verification. Success removes the test
FTP logins, files, domains, panel users and credential state; locked Linux
identities, private homes and pool definitions remain reserved as above.

The script never reboots automatically. Failed checks retain fixtures for
inspection. Use `sudo bash scripts/ftp-isolation-smoke cleanup` to cancel or
clean a failed run. Another `prepare` refuses to replace an existing run.

If FTP preparation fails after both fixtures were created, `retry` reruns the
protocol checks with the saved accounts once the cause is fixed. It refuses a
run that already passed preparation. On the Ubuntu 26.04 trial, vsftpd had been
started with stock system-user PAM authentication even though Hostctl virtual
users existed. `scripts/repair-ftp-setup` backs up the FTP configuration, applies
the running release's Hostctl FTP setup, restarts vsftpd, and calls `retry` using
the sibling wrapper. The installer now explicitly configures FTP after the
application starts; feature readiness also checks virtual-user configuration.


### Verified live trial and remaining acceptance check

On September 12, 2026, the Ubuntu 26.04/PHP 8.5 server passed both live scripts.
The initial isolation check passed distinct PHP UIDs, own-file access,
cross-owner file denial, private sessions, Nginx reads and symlink denial.
The FTP check passed actual login, upload/overwrite/rename/delete, ownership,
chroot and cross-owner denial. After a confirmed boot-ID change, the same test
identities, credentials, PHP pools and marker files still worked, and cleanup
removed the test domains, files, FTP logins and panel users. Identity reservations
and pool definitions remain by design. These results are from the live script
output supplied by the operator, not just local unit tests.

The trial exposed and fixed four fresh-install issues: legacy placeholder-file
permissions, enrollment of a matching empty admin owner, rendering category
result maps on the import progress page, and missing vsftpd virtual-user setup.
The FTP test wrapper's Elixir invocation was also corrected and regression-tested.

The operator then restored the pre-install snapshot and installed commit `338aa16`
from a locally transferred bundle, without incremental repair scripts. SSH checks
confirmed the pre-install paths were absent before installation, and confirmed the
installed commit and active Hostctl/Nginx/vsftpd/PHP services afterward. The operator
reported both the isolation check and FTP preparation passed, followed by a successful
Plesk import. Post-reboot FTP verification output for this final clean install has
not been supplied; only the earlier repaired trial has an explicit reboot pass.

Cloudflare was enabled manually after import. Live logs showed SRV payloads missing
`weight` and a duplicate NS record rejection. DNS synchronization fixes are now locally regression-tested in the separate
follow-up, with deployment pending. The system-identity question is about rapid
resource/process attribution for administrators. The user selected the resource
view and shell lookup, now implemented locally in `docs/account-resources.md`.
Recognizable Linux names remain deferred. See `docs/cloudflare-sync-follow-up.md`
for the assessment and deployment handoff.
