# VM development

Use a disposable VM with Hostctl installed by `priv/deploy/install.sh`. The
installer targets Ubuntu 22.04/24.04 and Debian 12, on ARM64 or x86-64.
This workflow uses the installer defaults (`hostctl` user and service,
`/etc/hostctl/env`). It runs Phoenix from source with code reloading, against the
VM's existing database, Nginx, PHP, Docker, FTP, and other hosting services.

Take a VM snapshot after installation. Development changes affect its real
hosting data and files. The development service and packaged release use the
same database and port, and the helpers stop one before starting the other.

## First setup

Run the normal installer on the VM once. Use a test panel hostname and keep SSH
access enabled. Complete initial panel setup and take your snapshot. No GitHub
push is needed for subsequent source edits.

On your Mac, from the repository root, copy the bootstrap helper (replace
`user@vm` throughout with your SSH address or config alias):

```sh
scp scripts/vm-dev user@vm:/tmp/hostctl-vm-dev
ssh -t user@vm 'sudo bash /tmp/hostctl-vm-dev prepare "$(id -un)"'
bash scripts/vm-sync user@vm --dry-run
bash scripts/vm-sync user@vm
```

`prepare` adds your SSH user to the `hostctl` group, gives it ownership of
`/var/lib/hostctl/dev`, and gives the group write access for compilation. If you
reuse a multiplexed SSH connection, reconnect after `prepare` so the new group
membership takes effect. It also creates a staging
certificate directory and adds an S3 proxy token to the installed environment
if one is missing. Secrets stay on the VM.

SSH into the VM and run:

```sh
cd /var/lib/hostctl/dev
sudo bash scripts/vm-dev setup
sudo bash scripts/vm-dev migrate
sudo bash scripts/vm-dev start
sudo journalctl -u hostctl-dev -f
```

The first dependency download and compilation take time. Later syncs preserve
the VM's `deps/` and `_build/` caches. `setup` installs Hex, Rebar, dependencies,
asset tools, Linux's `inotify-tools` for browser reloading, and the development
systemd unit. `migrate` stops both panel
services before applying migrations. `start` launches Phoenix and asset
watchers; follow the logs until the endpoint is listening.

Visit the existing panel hostname, pointed at the VM, through its Nginx
configuration. The Phoenix listener stays on `127.0.0.1:4000`, as expected by the
generated S3 proxy configuration. Use port 4000 for this workflow. For a private
panel without a working TLS frontend, an SSH tunnel provides direct access:

```sh
ssh -N -L 4000:127.0.0.1:4000 user@vm
```

Set `PHX_HOST=localhost` in the VM's `/etc/hostctl/env` and restart development
before opening `http://localhost:4000` through that tunnel. Restore the panel
hostname before returning to its Nginx frontend. This matters for LiveView's
WebSocket origin checks. The tunnel tests panel interactions; domain HTTP/TLS
tests must go through Nginx on ports 80/443.

## Everyday loop

Edit locally, then:

```sh
bash scripts/vm-sync user@vm
```

Refresh the browser as needed. Phoenix recompiles changed application code and
the asset watchers rebuild CSS/JavaScript. The helper syncs uncommitted edits
and removes deleted source files from the dedicated VM checkout. Do not edit
source in both places: the local checkout is authoritative. Git metadata,
dependencies, build output, and `.env*` files are excluded from syncing.

On the VM, use these only when needed:

| Change | Action |
| --- | --- |
| Elixir, HEEx, CSS, JavaScript | Sync and refresh |
| Configuration or application supervision | Sync, then `sudo bash scripts/vm-dev start` |
| Dependencies or asset tool versions | Sync, run `setup`, then `start` |
| Database migration | Sync, run `migrate`, then `start` |
| Service unit | Sync, run `setup`, then `start` |

Run focused `mix test` commands in an independently configured test environment.
The repository test config expects a local PostgreSQL `postgres` account with
password `postgres` and creates `hostctl_test`. The installer uses its own
credentials; do not weaken the installed database account to match the test
defaults. `HOSTCTL_VM_DEV` only applies to `MIX_ENV=dev`.

The development service is not enabled at boot. To return to the installed
release:

```sh
sudo bash scripts/vm-dev release
```

This switches processes, not database schemas or generated Nginx files. Use a
snapshot restore when you need to roll those back. The panel's updater should
only be exercised after switching back to the release; it builds the installer
checkout, not the synced development checkout.

## HTTP, S3, and certificates

VM development shares the production SSL redirect configuration, including the
`/_s3_proxy` exclusion. It reuses the installed database URL, encryption key,
database-server credentials, and S3 proxy token. Automatic scheduled backups
are disabled; manual hosting operations remain real.

Certbot uses Let's Encrypt staging with certificates stored in
`/var/lib/hostctl/letsencrypt-staging`. Production behavior is unchanged. Staging
certificates are intentionally untrusted by browsers. Staging still validates
domain ownership: HTTP-01 needs a publicly reachable challenge on port 80;
Cloudflare DNS-01 can validate through DNS without exposing the VM's HTTP port.
Wildcard requests use DNS-01. See the
[staging documentation](https://letsencrypt.org/docs/staging-environment/).

Reissue test-domain certificates in development before testing HTTPS: existing
production certificate records do not copy their files into the staging
directory. Regenerated Nginx configs may reference staging files even after
switching back to the release; restore the snapshot for a clean baseline.

Suggested first smoke test:

1. Create a test domain and serve a local file over HTTP.
2. Issue a staging certificate and verify HTTPS reaches the same file.
3. Toggle HTTP alongside HTTPS and inspect responses with `curl -I` instead of
   relying on cached browser redirects/HSTS. Use `curl -kI` for staging HTTPS.
4. Map an S3 path and compare HTTP/HTTPS responses and downloaded file contents.
5. Map a container port to a domain path, then test both protocols.
6. Import a small Plesk fixture into a snapshot and repeat the checks.

The current HTTP toggle is domain-wide. Per-directory/per-subdomain HTTP policy
and the SSL activation condition identified in the audit are separate follow-up
work, not fixed by this development setup.
