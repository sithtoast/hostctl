# Per-account system identities

Design and implementation roadmap, September 9, 2026. Identity reservations and
database preflight are implemented. The application still uses shared website
ownership and PHP sockets; runtime isolation is not yet implemented.

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

The next milestone is the Linux identity provisioner and service configuration
integration, followed by resumable ownership migration and two-account Linux
acceptance checks. Reserving an identity is not an activation gate yet: existing
provisioning continues to behave as before until those service changes land.

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

## Changes required together

| Area | Current code | Intended behavior |
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
