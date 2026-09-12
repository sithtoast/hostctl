# Cloudflare synchronization follow-up

September 12, 2026. This change is local; no public DNS mutation or deployment
was performed. Read-only SSH rechecked source HEAD `338aa16` and active Hostctl,
Nginx, vsftpd and PHP 8.5 services on `william@192.211.55.181`.

## Failure and correction

Plesk stores SRV priority separately from the `weight port target` value. Sending
that value as Cloudflare `content` omitted required SRV components. Hostctl now
sends `data.priority`, `data.weight`, `data.port` and `data.target` for creates
and edits. Malformed or out-of-range components fail before HTTP. Zero values
and the root target `.` (service unavailable) are preserved. Structured response
data is used when importing SRV records back into Hostctl.

The old zone synchronizer selected the first remote record sharing a name/type,
then replaced it. For two NS members this could attempt to turn the first into
the second, causing the observed identical-record error. It could also collapse
other multi-value sets. This is the code-level explanation; this task did not
retrieve the affected zone or reconstruct its historical writes.

The new linking and bulk-sync policy is:

- Match name, type and full DNS value first, including MX priority and all SRV
  components. DNS hostnames compare without case or terminal-dot differences;
  IPv6 compares canonical addresses. TXT/CAA content stays case-sensitive.
- Adopt an exact match without changing its TTL, proxy settings, comments or
  tags. Bulk sync deliberately does not reconcile TTL-only differences on
  exact matches; explicit record edits remain available for intended TTL edits.
- Otherwise update only an existing saved ID with the same name/type, unique
  among local rows, whose current value is not needed by another local row.
  Repurposed or ambiguous IDs fail for operator review. An exact match takes
  precedence over old incorrect IDs, repairing that local association.
- Add missing/unlinked values instead of overwriting remote peers. A deleted
  saved ID follows the same create path. Successful writes enter the in-memory
  snapshot so duplicate local rows do not create the same record twice.
- Updates use PATCH and omit provider-only attributes; proxied records retain
  automatic TTL. No records are deleted by zone synchronization. API failures
  remain failures; there is no destructive duplicate-error recovery.
- Cloudflare imports resolve a linked ID before adopting an unlinked local
  value, and distinguish MX/SRV priorities. They do not steal another linked
  row just because its content is identical.

This is not a transactional reconciliation engine. Concurrent external edits
between listing and writing remain possible. A failed API request or local ID
save requires fresh inspection/retry. Bulk sync reports per-record failure
counts; the existing link operation still returns the linked zone and logs
individual push failures. No automatic retry changes public DNS in this task.

Official contracts checked September 12, 2026:

- [Record types and structured SRV example](https://developers.cloudflare.com/dns/manage-dns-records/reference/dns-record-types/)
- [Create record schema](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/create/)
- [PATCH record endpoint](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/edit/)

Cloudflare also documents name/type coexistence restrictions, including NS and
CNAME conflicts. These fixes do not remove conflicting records or alter zone
nameserver delegation. Such errors need explicit record-set review.

## Validation

`mix precommit` passes, including warnings-as-errors compilation, formatting and
the full suite. The final count is recorded in `docs/development-memory.md`.
HTTP regression tests use `Req.Test`; they cannot contact public Cloudflare.
Coverage includes the three mail SRV services, numeric validation, NS shared-ID
repair, multi-value additions, duplicate local rows, stale and repurposed IDs,
required-value protection, canonical names/IPv6, import priorities, API failure
propagation and preservation of Cloudflare attributes.

The full suite also emitted a background `reset_orphaned_upload_jobs/0` SQL
sandbox connection error during startup. No test failed, and compilation passed.
This startup task is outside the DNS change. Live Cloudflare acceptance remains
unverified. The final clean install's post-reboot FTP verify output is still
outstanding; do not infer it from the earlier repaired trial's successful run.

## Proposed deployment and acceptance

These steps are prepared for a later authorized maintenance window. Do not use
the normal updater to fetch this unpublished patch from GitHub. No migration,
installer rerun, account enrollment or ownership repair is needed for this fix.

1. From the local fix branch, create a bundle and record the full commit:

   ```bash
   git rev-parse HEAD
   git bundle create /tmp/hostctl-cloudflare-sync.bundle HEAD
   git bundle verify /tmp/hostctl-cloudflare-sync.bundle
   ```

2. Transfer the bundle with the explicit test-server key, then enter the server:

   ```bash
   scp -o IdentitiesOnly=yes -i /Users/wmh/.ssh/hostctl_ubuntu26_agent \
     /tmp/hostctl-cloudflare-sync.bundle william@192.211.55.181:/tmp/
   ssh -o IdentitiesOnly=yes -i /Users/wmh/.ssh/hostctl_ubuntu26_agent william@192.211.55.181
   ```

3. Recheck services and revision. Take a VM snapshot and retain the current
   release plus `/etc/hostctl/commit` before the swap. In an interactive root
   shell (`sudo -i`), build in a new source directory, comparing HEAD against
   the full commit recorded in step 1:

   ```bash
   git clone /tmp/hostctl-cloudflare-sync.bundle /usr/local/src/hostctl-cloudflare-sync
   cd /usr/local/src/hostctl-cloudflare-sync
   git rev-parse HEAD
   git rev-parse HEAD > priv/COMMIT
   MIX_ENV=prod mix deps.get --only prod
   MIX_ENV=prod mix assets.setup
   MIX_ENV=prod mix assets.deploy
   MIX_ENV=prod mix compile --warnings-as-errors
   MIX_ENV=prod mix release --overwrite
   ```

4. After a successful build, announce the panel interruption. Stop `hostctl`,
   save `/opt/hostctl` as the rollback release, copy the new
   `_build/prod/rel/hostctl` to `/opt/hostctl`, and set that release's ownership
   to `hostctl:hostctl`. Preserve `/etc/hostctl/env` without displaying it.
   Copy `priv/COMMIT` to `/etc/hostctl/commit`, then start `hostctl`. Keep the
   active-source location documented; the old `/usr/local/src/hostctl` has not
   been changed by these staging steps. Do not run the stock update button
   until its source/ref points to an authorized release containing this patch.

5. Confirm services are active and the panel is accessible. Verify the packaged
   `Hostctl.DNS.Record` module and running revision over release RPC with the
   installed environment loaded privately. If startup fails, stop Hostctl,
   restore the saved release and commit marker, and start it again. This patch
   has no database migration to roll back.

6. First use a disposable Cloudflare test zone after explicit DNS-write approval.
   Seed two NS members at a delegated name, multiple MX/TXT/A members and the
   three mail SRV records. Keep a before/after export including record IDs,
   TTL, proxy flags, comments and tags. Link/sync, then sync again: exact sets
   must remain unchanged, missing SRVs must contain all four fields, and the
   second pass must add nothing. Test a changed uniquely linked member and an
   ambiguous link; only the first may be patched. Inspect partial failures.

7. Before any `crohnies.org` sync, review its current local and remote sets and
   approve the exact intended differences. Prior behavior might already have
   altered records; do not reconstruct lost values automatically. Then confirm
   the intended records in Cloudflare and through authoritative DNS queries.
   Restoring the application release does not undo public DNS writes.

## Operator identity design (not implemented)

The user clarified that rapid attribution of runaway processes/resource usage
is the goal, including for future administrators of a commercial Hostctl install.
A label confined to the panel would not solve SSH triage by itself.

One option is a resource view showing account, domains, Linux name/UID and
CPU/memory, paired with a shell lookup by username, UID or PID. Stable `hc_*`
identities remain intact. An actual recognizable name in standard `ps`/`top`
requires a managed Linux user/group rename instead.

The latter must preserve UID/GID and reserve names against collisions and reuse;
change the database name constraint and privileged helper contract; quiesce the
account's writers; migrate ownership markers, homes/private paths, PHP pools and
sockets, Nginx references and FTP mappings; validate isolation; and journal enough
state for recovery from a partial failure. Changing email/domain/display name
must not implicitly rename an OS identity. No live `usermod`/`groupmod` operation
is authorized by this follow-up. The choice between the operational lookup and
recognizable OS names remains pending.
