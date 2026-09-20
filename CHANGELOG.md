# Changelog

User-facing changes are recorded here, starting with the DNS provider feature.
Earlier changes remain in Git history and GitHub release notes. Version headings
describe source changes; publication and build numbers are tracked by GitHub releases.

## Unreleased

## 0.15.0

### Added

- Web and mail hosting choices when adding a domain, with optional DNS template
  application. Web-only domains skip Hostctl mail records and local mailbox setup;
  mail-only domains skip web provisioning and web DNS defaults.
- Service labels on DNS templates, including automatic classification of standard
  records and explicit labels for custom templates.

### Changed

- Domain service links, mailbox creation, mail configuration exports, Email Delivery
  publication and traffic collection respect the selected hosting services.
- Existing domains keep their enabled services. Provider synchronization preserves
  external mail records; manually managed DNS remains available for external services.

## 0.14.0

### Added

- DigitalOcean DNS at panel and domain levels, including access checks, linking an
  existing zone, viewing/importing records, and record creation, editing, deletion
  and bulk sync.
- Per-domain Cloudflare and DigitalOcean API tokens. Customers and resellers can
  use their own provider accounts independently of the panel default, within
  existing domain ownership permissions.
- Encrypted, masked domain credentials with explicit removal and panel-token
  fallback. Blank fields keep the saved token.
- `mix hostctl.version.bump patch|minor|major` updates the source version and
  changelog together; GitHub continues assigning build numbers automatically.

### Changed

- DNS operations, Cloudflare certificate provisioning and Email Delivery resolve
  each domain's provider and credentials. Linked zones retain their provider when
  the panel default changes.
- Credential changes retire affected zone links and record IDs. Rotating a panel
  token preserves domains using their own tokens. Saving settings and checking
  access do not modify remote DNS.
- DigitalOcean synchronization preserves distinct MX, TXT and SRV values, supports
  CAA and delegated NS records, and reports failed writes without discarding local
  records. Bulk sync leaves unrelated remote records intact.

### Limitations

- Create DigitalOcean zones and change authoritative nameservers outside Hostctl.
  Access checks verify read access only; they do not verify write permissions or
  public DNS delegation.
- DigitalOcean domains use HTTP-01 certificates. Wildcard DNS-01 and automatic
  Email Delivery DNS publication remain Cloudflare-only.

See [DNS setup and validation](docs/digitalocean-dns.md) for details. This version
is prepared locally; no release or deployment has been performed by this work.
