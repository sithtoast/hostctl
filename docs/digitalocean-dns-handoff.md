# DigitalOcean DNS follow-up

September 12, 2026. User approved the statistics preview, requested merging the
finished work into local main, and asked to start a new chat for **DigitalOcean
DNS support at both panel and domain levels**. Continue implementation in the new
task/worktree; do not stop at another plan. No push or live DNS changes were requested.

## Starting state

The completed statistics/import work includes these feature commits:

- `bd5b46c`: private GoAccess statistics, preserved Plesk history, and final import
  progress correlated with the exact customer-owned background transfer jobs.
- `3b42d65`: collection defaults on for existing/new domains, persisted per-domain
  opt-out, GoAccess in new installs, and pinned Solid deployment launcher.
- `fd2b110`: native summary totals/top pages/referrers and a separate full-report
  tab, replacing the embedded GoAccess window. User reviewed and approved locally.

Final validation: `mix precommit` 302 passed, minified asset build passed, and
browser checks verified the summary and functioning standalone GoAccess report.
Earlier real-GoAccess ingestion suite: 5 passed. No feature code changed after
those checks. See `domain-stats-import-handoff.md` and `domain-statistics.md`.

The current task has a disposable local preview running at
`http://localhost:4421/domains/1/statistics`, with synthetic live and Plesk history.
Database `hostctl_teststats_overview`, script `/tmp/hostctl-overview-preview.exs`,
private sample files `/private/tmp/hostctl-overview-preview`. It was left running
and opened for the user; do not interrupt it unexpectedly or treat it as Solid.

Solid's latest independently read release stamp was `68eb2c4`; user has not supplied
installation output since. `/tmp/hostctl-statistics-3b42d65/apply` and its bundle
were staged and checksum-verified on Solid. That bundle does not include the later
native-summary UI. Do not claim current deployment from the original source
checkout: `/usr/local/src/hostctl` remained at `338aa16` while the release advanced.
Read `development-memory.md` before any VM work and recheck live state. Sudo needs
interactive operator input. Neither a deployment nor DNS writes are in this task.

## Next implementation

Read AGENTS.md and inspect existing Cloudflare/manual DNS provider behavior before
choosing the integration. Primary entry points:

- `lib/hostctl/settings/dns_provider_setting.ex`, `lib/hostctl/settings.ex`
- `lib/hostctl/hosting/dns_zone.ex`, `lib/hostctl/hosting/dns_record.ex`
- `lib/hostctl/dns/cloudflare.ex`, `lib/hostctl/dns/record.ex`
- panel settings, domain DNS LiveViews, related email-delivery DNS consumers

Add DigitalOcean provider configuration, encrypted credentials and token checks,
panel defaults plus domain selection/override consistent with existing ownership
rules, and zone/record operations needed by those flows. Inspect existing
panel-hostname and certificate/DNS-01 integrations too so provider limitations are
explicit and the new option is not accidentally routed through Cloudflare code.
Use Req. Consult current official DigitalOcean API documentation for record
fields, pagination, token permissions, errors and provider limitations.

Preserve Cloudflare behavior, manual DNS, no-domain restrictions and existing
multi-value/SRV reconciliation safeguards. Never silently migrate a live zone or
change authoritative nameservers when saving a provider preference. New routes,
if needed, belong in the existing appropriate authenticated/admin scopes.

Validate with HTTP stubs and meaningful context/LiveView tests for provider
selection, permission boundaries, credential handling, records (especially MX,
TXT, SRV and multiple values), errors and pagination. Use an isolated local preview
for UI acceptance. Run `mix precommit`, update the handoff, and commit locally.
Do not print tokens, change real DNS, enable SSH, push or deploy without the user's
request for that action. Ask only for material product choices that cannot be
resolved from existing behavior; keep progressing on independent work.

## Implementation completed in separate worktree

September 12, 2026: branch `codex/digitalocean-dns`, worktree
`/Users/wmh/.codex/worktrees/3f39/hostctl`. See [digitalocean-dns.md](digitalocean-dns.md)
for behavior, credential/link lifecycle, API references and explicit support limits.
Panel defaults/credentials and ownership-checked domain selection/token overrides
are implemented. Linked zone record CRUD, refresh/import and conservative sync are
covered by API/context/LiveView tests. Cloudflare/manual DNS remain available.

Final precommit: **323 passed**; asset build passed; isolated port **4422** browser
preview verified panel token checks and domain linking/refresh/import with synthetic
A/MX/TXT/SRV records. DNS calls in that preview are stubbed; writes are rejected.
Port 4421 was not interrupted. No real DNS/nameserver changes, push or deployment.
Solid's staged-versus-verified state above is unchanged. DigitalOcean wildcard
DNS-01, automatic panel-hostname DNS and Email Delivery automatic apply remain
explicitly unsupported; normal HTTP-01 and manual email plans remain available.

### Cloudflare per-domain credentials follow-up

The user's follow-up requested customer/reseller-supplied Cloudflare credentials.
Domain provider forms now accept encrypted, masked Cloudflare tokens with blank
preservation, explicit removal, read-only zone access testing and panel fallback.
DNS operations, Email Delivery and Cloudflare DNS-01 all use the effective domain
token. Rotation clears affected links/IDs without remote changes; panel rotation
preserves independently credentialed zones. Existing ownership boundaries remain.

Validation: **331 passed** via mix precommit; assets built; browser checks on
`http://localhost:4422/domains/2/dns` verified masked credentials, read-only access
check, linking and remote A/MX listing against stubs. Offline Certbot credential
selection/cleanup passed without requesting a certificate. Port 4421 remains
untouched. No push, deployment, real DNS or nameserver changes.
