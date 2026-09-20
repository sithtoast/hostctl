# Domain hosting services

When adding a domain, choose **Web hosting**, **Mail hosting**, and whether to
**Add default DNS records for selected services**. Both hosting services default
on for compatibility. For an existing external mail provider, uncheck Mail hosting.

- Web hosting creates the normal website runtime and web DNS defaults. With it
  unchecked, Hostctl does not provision an Nginx vhost, PHP pool or webroot. Web
  subdomain/S3 creation is rejected, certificate provisioning is disabled and
  automatic traffic collection skips the domain.
- Mail hosting permits local mailbox creation and Hostctl Email Delivery setup.
  With it unchecked, mailbox creation is rejected, the domain is excluded from
  Postfix/Dovecot account exports and the Email Delivery domain picker, and email
  DNS preview/publication and local signing setup are blocked.
- DNS management stays available independently. With both services unchecked and
  the template disabled, the domain starts with an empty local zone. Manually
  create or import records for externally hosted services as needed.

Selecting services only affects new domains. Existing domains migrate with both
services enabled, preserving their current records and runtime. Ordinary domain
edits cannot toggle these flags: changing live service ownership requires a future
explicit transition flow. Domain backup metadata includes both selections.

## DNS templates and external mail

Filtering happens before template records are inserted, so the same local zone
is used by Cloudflare and DigitalOcean linking and synchronization. Mail templates
are absent when mail hosting is off. Standard MX, SPF, DMARC, DKIM, mail/webmail
addresses, mail autodiscovery and common mail SRV records are recognized. Unrelated
TXT verification records remain. Standard root/WWW/FTP/IPv4/IPv6 address templates
are treated as web records. NS and other general records are independent of web
and mail hosting.

Panel Settings lets administrators label each template **Automatic**, **Web
hosting**, **Mail hosting**, or **Always include**. Existing templates default to
Automatic. Use an explicit service for nonstandard names, such as a custom mail
host. Explicit labels override automatic classification; Always include applies
regardless of service choices. Review custom templates before using them.

Creating a domain does not modify public DNS. Cloudflare linking can publish local
records as part of its existing behavior; DigitalOcean linking only reads and its
Sync action publishes. Both providers leave unrelated external MX/SPF/DKIM records
alone. These choices do not delete or rewrite existing provider records. They also
do not prevent explicit manual DNS changes for an external mail provider.

The domain creation page stays in the existing authenticated browser pipeline and
`:require_authenticated_user` LiveView session. Template controls remain in the
existing admin-only Panel Settings route. No routes were added.

Plesk imports retain their existing defaults and category selections; this change
adds service selection to the Add Domain flow, not automatic inference from Plesk
or public DNS. Database and FTP resource management remains separate from these
web/mail service choices. Global installation features are unchanged.

## Validation

- `ERL_FLAGS='+S 4' MIX_TEST_PARTITION=services mix precommit`: 343 tests passed.
- `mix assets.build`: passed.
- Context and LiveView tests cover web-only, mail-only, empty-zone creation,
  existing defaults, retained selections, custom mail templates, manual external
  MX management, mailbox rejection and stale caller protection.
- Stubbed Cloudflare and DigitalOcean checks verify no generated mail writes and
  no mutation of an existing external MX during linking/sync. A web-enabled test
  runtime with an intentionally unusable Nginx command verifies mail-only creation
  and subsequent sync skip web provisioning.
- Browser validation uses disposable database `hostctl_testservices_preview` on
  port 4423 with all hosting integrations disabled and provider requests blocked.
  Desktop and mobile layouts were checked. Saving a synthetic web-only domain
  retained its selection and hid mailbox controls.
- No real provider, DNS, mail, certificate, Linux service, push or deployment
  acceptance is implied by these local checks.
