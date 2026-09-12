# Domain traffic statistics

Hostctl uses GoAccess for private, per-domain reports. Open a domain and choose
**Traffic statistics**, then **Start collecting**. Administrators can install
**Domain Statistics** from Administration → Features. The first successful
collection enables hourly updates; **Refresh traffic** collects immediately.
The domain and its configured local/S3 subdomains are included.

Reports show requested pages, downloads, referrers, HTTP errors, traffic and
estimated visitors. They are server-log statistics: bots are included, referrers
can be absent, and CDN cache hits that never reach the server are absent.
Countries require a service-readable GeoIP MMDB file configured with
`HOSTCTL_GEOIP_DATABASE` in `/etc/hostctl/env`, plus accurate client-IP logging.
Hostctl does not download a GeoIP database or change trusted-proxy settings.
Query strings are omitted from newly generated requested-URL statistics.

## Collection and retention

Collection runs as the Hostctl service user, with Python 3 and GoAccess installed
from the OS package repository. Private snapshots and persistent GoAccess state
live under `/var/lib/hostctl/statistics/<domain-id>` (directories 0700). Existing
installations gain this directory when installing the feature; the installer
also creates it for new deployments. The standard service's supplementary `adm`
group must be able to read the domain's Nginx access logs.

Each run reads `<host>.access.log.1` and `<host>.access.log` directly, using
GoAccess's inode-aware `--persist`/`--restore` behavior. Normal Ubuntu rename/create
rotation is supported. Do not replace these inputs with copied files, stdin, or
copy-truncate rotation and assume equivalent accounting. The initial report
covers only those retained inputs. Logs that rotate away during a collection
outage cannot be recovered automatically; older compressed live logs are not
backfilled. Failed collection leaves the previous report and timestamp intact.

Per-domain locking prevents concurrent writers. Successful report generations
are published atomically; active live/history generations and recent generations
are retained. There is no time-based purge of aggregate data yet. Current limits
are 1 GiB per input, 4 GiB per run, a 300-second GoAccess timeout and 2 GiB GoAccess
address-space limit. Report downloads are capped at 32 MiB. Large sites may need
a separate analytics service or revised resource/retention policy.

## Preserving Plesk history

For a **Direct SSH** import, discover/select **Statistics history**, then select
**Statistics History** for the domain. The importer copies known Plesk system
statistics, legacy statistics and access-log directories into private staging.
It never runs Plesk CGI programs or configuration. Symlinks and special files are
excluded from transfer and rejected by the history reader.

The **Plesk history** tab preserves HTML reports and `awstats*.txt` aggregate data.
HTML is sanitized and served without scripts; external images, styles and
cross-report navigation may be absent. The preserved original bytes remain in
private storage. AWStats aggregate data cannot be converted back into individual
requests. Retained Combined-format `access_log`, `access_ssl_log` and corresponding
`proxy_` logs (including gzip rotations) can rebuild a separate GoAccess report.

Byte-identical log copies are parsed once. Proxy logs are preferred over Apache
logs separately for HTTP and HTTPS to avoid counting both views of a request.
Non-identical logs with repeated request lines across files are conservatively
considered ambiguous: files are preserved with a warning and no rebuilt totals.
Provide a non-overlapping set to rebuild. The overlap index is bounded to two
million lines and five minutes. Unsupported log formats or unavailable GoAccess
also preserve supported history with an explanatory warning. These warnings do
not mean missing detail was recovered.

History imports replace the previous historical snapshot; they never add its
counts to new Hostctl traffic. Keep a separate original backup for long-term
archival retention. History import limits are 20,000 entries, 8 MiB per preserved
report, 1 GiB per log and 4 GiB total after decompression.

For an **already extracted** backup/history directory, use the installed command
(domain ID is visible in the domain page URL):

```sh
sudo /opt/hostctl/bin/statistics collect 123
sudo /opt/hostctl/bin/statistics history 123 /absolute/private/path/to/domain-history
```

The wrapper reads the installed environment privately and drops to `hostctl`
before generating files. The history directory and its parents must be readable/
traversable by that service user; use a private service-owned staging directory,
not a public document root. The command does not extract arbitrary backup archives.
Source checkouts provide equivalent `mix hostctl.statistics collect 123` and
`mix hostctl.statistics history 123 /absolute/path` commands with the configured
repository environment. They start repository access without hosting workers.

## Access boundaries

The LiveView uses the existing `:require_authenticated_user` live session under
the `:browser` and `:require_authenticated_user` pipelines. The controller report
route uses the same authenticated scope. Both check domain ownership or explicit
administrator access; report URLs do not bypass login.

GoAccess HTML runs in an opaque-origin sandbox allowing scripts, without
`allow-same-origin`. Its bundled template compiler requires `unsafe-eval` only
on this isolated report response. Network connections, forms and external assets
are blocked. Preserved Plesk HTML has scripts disabled and is additionally
sanitized. All reports use private/no-store caching and no-referrer headers.

## Validation and VM acceptance

Local tests cover domain authorization, private archived HTML, path/symlink
rejection and report routing. Real GoAccess integration tests exercise repeated
refresh, same-timestamp appended requests, rename/create rotation, atomic failure,
Plesk snapshot replacement, duplicate copies, partial overlaps and invalid logs:

```sh
docker build -t hostctl-goaccess-test:local test/statistics
docker run --rm -v "$PWD":/workspace:ro -w /workspace \
  hostctl-goaccess-test:local python3 -B -m unittest discover -s test/statistics -v
mix precommit
```

A local isolated browser preview verified the generated report and the live
import-completion transition using synthetic data. This does not establish Solid
VM installation, production log readability, real Plesk archive compatibility,
GeoIP results or restored website/mail behavior. Before a separately authorized
VM rollout, follow `development-memory.md`, verify the running release, install
the optional feature, collect a known test domain and inspect its report. Confirm
real log rotation and import representative Plesk history before broad migration.
