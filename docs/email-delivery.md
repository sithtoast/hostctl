# Email delivery setup

Admin navigation: **Email Delivery** (`/panel/email-delivery`). The route uses the
existing `:require_admin` LiveView session, within the browser pipeline and
`:require_authenticated_user` plug. Client and reseller accounts cannot publish
server-wide mail changes through this page.

## Setup

1. Choose a domain. Hostctl reads its configured per-domain relay, falling back to
   the server relay and then direct sending. Apply relay changes in the existing
   Smarthost settings before continuing; this page does not alter Postfix routing.
2. For direct sending, enter the actual public IPv4/IPv6 egress addresses and
   Postfix mail hostname. Include NAT addresses and every IP used for delivery.
   Apply Spam Protection first, then **Prepare DKIM key**.
3. For a relay, enter its SPF include hostname and the DKIM TXT/CNAME records
   supplied by that provider. The domain's Mailgun shortcut stages these values
   automatically; save its relay form before previewing delivery DNS. That
   shortcut no longer replaces DNS policies in the background.
4. **Save and preview DNS**. Existing SPF senders and final policies are retained.
   New SPF uses `~all`. New DMARC uses `p=none`, without assuming a report mailbox
   exists. Existing DMARC is preserved. Inbound MX and unrelated TXT are untouched.
5. **Publish reviewed changes to Cloudflare**, or copy the exact records to another
   provider. Hostctl reads every Cloudflare record page and checks the snapshot
   again before writing. Conflicts, duplicate authentication policies, unsupported
   SPF mechanisms, SPF lookup-budget failures, and expired previews block writes.
   It turns off Cloudflare proxying only for the matching reviewed mail-host record.
6. **Verify public DNS** runs automatically after successful publication and can
   be repeated after propagation. Provider acceptance is distinct from public
   verification. Checks use Cloudflare's public DNS-over-HTTPS resolver; other
   resolvers may retain older data until TTLs expire.
7. For direct sending, **Enable signing after DNS verification** verifies the exact
   public key again and applies the managed Rspamd configuration. It signs only
   authenticated SMTP mail with a matching sender domain. Websites must use
   authenticated SMTP. This does not install an SMTP submission/authentication
   service; configure one if your server does not have it. Mail clients may briefly
   reconnect during the apply operation.
8. Set PTR through the IP hosting provider so it matches the mail hostname, whose
   A/AAAA must point back to the same IP. Hostctl verifies that pair. Confirm the
   real Postfix HELO and sending addresses, and send a test message to inspect SPF,
   DKIM and DMARC results. Relay signing must be enabled at the relay provider.

## Operational behavior

Public DNS lookup errors are not treated as absent records. Existing CNAME owners
are protected. Plans expire after 15 minutes. A failed provider write stops the
batch and reports the number of acknowledged changes; it does not claim rollback.
Re-preview to reconcile provider state before retrying. Cloudflare has no atomic
multi-record transaction: avoid concurrent edits in another DNS client while a
publication is running. The local DNS mirror updates acknowledged records; public
Cloudflare state and subsequent verification are the source of truth.

Private RSA-2048 keys are generated on Linux under
`/var/lib/hostctl/dkim/<domain>/<selector>.key`, owned by root with group `_rspamd`
and mode 0640. Parent directories are root-owned and group-traversable. Only the
public key and selector enter the database. Existing selectors are reused; missing
published private keys require restoration from backup and are never regenerated
silently. Include this protected directory in server backups. Automated key
rotation is not implemented.

DKIM signing is part of the managed Spam Protection configuration and its health
checks/rollback. Disabling Spam Protection also stops this local signing. DNS keys
are left published, as are existing provider policies. Relay-specific DKIM is
independent of the local signer. New default DNS templates use explicit IPv4 SPF
and monitoring DMARC; previously saved templates and existing records are not
mass-updated.

Authentication prevents some deliverability mistakes and domain spoofing. It does
not guarantee inbox placement, inspect reputation lists, or impose outbound rate
limits. Compromised mailboxes and websites still need sending-abuse controls.

## Validation

- `mix precommit`
- Existing spam installer rollback unit tests in `test/spam_protection`.
- Real Linux key-generation, Rspamd signing and OpenSSL signature verification:
  generate `/tmp/hostctl-dkim-bundle.json` with
  `mix run --no-start scripts/dkim-test-bundle.exs`, then run
  `test/email_delivery/integration.py` in the disposable spam-test Docker image,
  mounting the bundle at `/bundle.json` and `priv/email_delivery/key.py` at `/key.py`.
  No production mailboxes, keys, credentials or DNS writes are involved.
