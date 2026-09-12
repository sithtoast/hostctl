# DigitalOcean DNS

Implemented September 12, 2026. Panel settings and domain DNS support DigitalOcean
alongside Cloudflare and local/manual DNS. No provider selection changes public DNS.

## Panel and domain setup

1. An administrator selects DigitalOcean in **Panel Settings → DNS Provider** and
   saves a personal access token with `domain:read`, `domain:create`, `domain:update`
   and `domain:delete` scopes. **Test saved token** reads the domains endpoint; it
   verifies read access only, not write authorization or authoritative delegation.
2. In a domain's DNS manager, its owner or an administrator chooses **Use panel
   default**, **Local / manual**, **Cloudflare**, or **DigitalOcean**. A domain can
   supply its own Cloudflare or DigitalOcean token or use the matching panel token. Domain owners cannot
   view or change panel credentials. Users without a domain cannot access another
   owner's zone; provider operations recheck ownership in the context.
3. Create the zone in DigitalOcean outside Hostctl, then choose **Link existing
   zone**. Linking verifies the exact domain and stores its name; it makes no DNS
   writes. Zone creation/deletion and registrar nameserver changes are intentionally
   outside this integration.
4. **Refresh remote records** reads the remote record set. **Import remote records**
   refreshes it again and imports supported values locally. **Sync all to
   DigitalOcean** publishes local values after an explicit confirmation. Once
   linked, record additions, edits and deletions in the DNS manager sync immediately.

Linked zones remain pinned to their provider if the panel default changes. Existing
Cloudflare links therefore continue working. Changing a domain provider or token
clears its links and both providers' record IDs, without deleting remote data.
Rotating the panel Cloudflare or DigitalOcean token unlinks only zones using that token;
domain-token zones keep their links. Relink and review/import before publishing.

Blank token fields preserve saved credentials. The removal checkbox explicitly
clears the chosen domain token (or the panel DigitalOcean token). New credentials use `Hostctl.EncryptedField` at rest;
struct inspection redacts them, password inputs never render saved values, Phoenix
filters token parameters, and credential writes suppress SQL parameter logging.
The encryption key is the endpoint's stable `secret_key_base`; preserve it across
releases. Cloudflare uses the same encrypted type for new writes and retains legacy
plaintext read compatibility.

## Records and errors

The Req client implements read-only token checks, exact zone lookup, paginated
record listing, POST creation, PATCH updates, and DELETE. Pages use a fixed API
origin and sequential page numbers, never credential-bearing response URLs.
Redirects and automatic write retries are disabled. HTTP errors and transport
failures return safe messages without echoing provider responses or tokens.
Malformed record pages fail instead of masquerading as an empty zone.

A, AAAA, CNAME, MX, TXT, SRV, CAA, and delegated NS records are supported. SRV stores
priority separately from `weight port target`, matching Hostctl/Plesk conventions.
CAA uses `flags tag value`. Values are matched using complete record data; MX/SRV
priority distinguishes members and TXT values remain case-sensitive. Bulk sync
adopts exact remote values without rewriting their TTL. Explicit TTL edits on a
uniquely linked record update DigitalOcean. Duplicate local values reuse one remote
record. A linked ID cannot replace another name/type, overwrite a value another
local row needs, or ambiguously update/delete a shared ID.

Bulk sync reports successful and failed counts and carries successful creates
forward, avoiding duplicate writes within a run. It never deletes unrelated remote
records. Local form saves roll back on failed remote writes; failed deletes retain
the local row. A network failure after provider acceptance can still leave an
uncertain remote result: refresh/import before retrying. Remote APIs and PostgreSQL
cannot share one atomic transaction. Generated subdomain records that fail to sync
remain local, are logged without credentials, and can be retried with Sync all.

The DNS list shows **Linked** for a known provider record ID, not a claim that live
DNS or delegation has been verified. **Pending sync** means no provider record ID.

## Explicit support limits

- Apex NS writes/deletion are disabled; exact existing NS values may be adopted or
  imported. SOA and unknown record types are not imported. Authoritative nameserver
  changes require the operator's separate action outside Hostctl.
- DigitalOcean requires TTL >= 30 seconds. Unsupported CAA semicolon values and
  flags outside 0..255 fail before an HTTP write.
- DigitalOcean provides DNS, not Cloudflare's traffic proxy. This feature does not
  enable proxy mode, alter Nginx's origin mode, or change installer flags.
- Domain certificate provisioning selects the domain's effective provider.
  DigitalOcean/manual domains use HTTP-01. Wildcard certificates remain supported
  only through the existing Cloudflare DNS-01 plugin; both UI and backend explain
  the DigitalOcean limitation. An unrelated panel Cloudflare default cannot cause
  a DigitalOcean domain to use Cloudflare DNS-01.
- The installer's panel-hostname flow in `priv/deploy/install.sh` remains webroot
  HTTP-01 unless its separate Cloudflare proxy mode is selected. Panel DNS settings
  do not create a panel-hostname record or provision a wildcard panel certificate.
- Email Delivery uses the domain's effective provider. DigitalOcean domains use
  public DNS inspection and the existing manual plan; its automatic DNS apply
  remains Cloudflare-only. Required records can be managed in the domain DNS page.

## Verification

- `ERL_FLAGS='+S 4' MIX_TEST_PARTITION=digitalocean mix precommit`: **331 passed**.
  Includes HTTP stubs, ownership/no-domain boundaries, encrypted token persistence,
  overrides/rotation, pagination, errors, multi-value/SRV/CAA reconciliation, CRUD,
  TTL edits, and panel/domain LiveView interactions. Existing Cloudflare and email
  tests pass. The suite still emits existing startup SQL-sandbox/background-task
  diagnostics and expected failure-path logs; there were no failed tests.
- `mix assets.build`: passed. The pinned Tailwind 4.1.12 macOS executable needed a
  local ad-hoc signature after its vendor signature was rejected; this changed
  only an ignored build tool, not application/deployment files.
- An isolated preview on **http://localhost:4422/domains/1/dns** uses database
  `hostctl_testdigitalocean_preview` and `/tmp/hostctl-digitalocean-preview.exs`.
  All Cloudflare/DigitalOcean HTTP calls are stubbed; mutations are rejected.
  Browser checks verified the panel read-access result, masked inputs, zone link,
  remote list, import, MX priority, SRV values, and the rendered table/layout.
- No real token/API acceptance, public DNS propagation, certificate issuance,
  nameserver change, push, VM update or deployment was performed. The existing
  statistics preview on port 4421 was left running.

## Official references checked September 12, 2026

- [DigitalOcean Domain Records API](https://docs.digitalocean.com/reference/api/reference/domain-records/): request fields, bearer auth, scopes, record CRUD, pagination.
- [DigitalOcean Domains API](https://docs.digitalocean.com/reference/api/reference/domains/): exact domain lookup and read-only token check.
- [DigitalOcean DNS limits](https://docs.digitalocean.com/products/networking/dns/details/limits/): TTL and CAA limitations.

## Cloudflare customer tokens (September 12 follow-up)

Domain owners, including reseller-owned domains, can save an encrypted Cloudflare
API token under **Domain DNS provider**. Set the provider override to Cloudflare to
use it independently of the panel default. Blank inputs retain the saved token;
**Remove Cloudflare domain token and use panel credentials** clears it and unlinks
the zone. Existing domain ownership and admin route boundaries remain unchanged;
this feature does not grant a reseller access to unrelated customer domains.

Use a scoped bearer API token with Zone Read and DNS Edit for the intended domain,
not a legacy global API key. **Test saved Cloudflare access** performs exact-domain
lookup and record listing without linking or writing; it does not prove write
permissions. Link, sync, import, record CRUD, Email Delivery preview/publication,
and Cloudflare DNS-01 certificate provisioning all resolve the domain token before
falling back to the panel token. Email Delivery's administrative access rules are
unchanged. The installer panel-hostname flow is still separate.

Credential changes retire record IDs and zone links without changing remote DNS.
Cloudflare link/list/sync reload the stored zone, preventing an old open page from
reusing a link after token rotation. Unlink clears Cloudflare record IDs. Imports
refresh the remote set rather than reusing a cached set from an older credential.
Rotating a panel Cloudflare token leaves domains using their own tokens linked.

Validation: full precommit **331 passed**, asset build passed, and browser checks at
**http://localhost:4422/domains/2/dns** verified a saved/masked domain Cloudflare token,
read-access check, linking and remote A/MX listing while the panel default remained
DigitalOcean. All DNS API calls were stubbed. An offline Certbot executable verified
that the domain token reaches DNS-01 and the temporary credentials file is removed;
no certificate was requested. Tests also cover blank preservation, explicit removal,
rotation, stale links, ownership restrictions, DNS CRUD and Email Delivery token
selection. Port 4421 was untouched; no real DNS changes, push or deployment.

Cloudflare references checked September 12, 2026:
[API token templates](https://developers.cloudflare.com/fundamentals/api/reference/template/)
and [permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/).
