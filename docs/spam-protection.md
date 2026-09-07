# Spam Protection

Administrators can open **System → Spam Protection** (`/panel/spam-protection`).
The route is in the existing `:require_admin` LiveView session, within the
`/` scope using `[:browser, :require_authenticated_user]`. Context functions
also require an administrator scope.

## Enable and use

1. Install and configure Hostctl's **Email Server** first.
2. Open Spam Protection, enable protection and learning, and save defaults.
   Start with the default Junk threshold of 6.
3. Optionally select a mailbox and save a threshold or sender rules. A blank
   mailbox threshold inherits the server default. Clearing both sender lists
   and the threshold restores default behavior.
4. Click **Apply saved settings**. Saving alone does not change delivery. The
   page distinguishes saved policy from the last successfully applied bundle.
5. Move missed spam into the IMAP folder named `Junk`; move wanted mail from
   `Junk` to `INBOX`. Webmail and other IMAP clients can provide this feedback.

Scores at or above the mailbox threshold go to Junk. The generated policy
has no score-based rejection or deletion. Sender rules match the SMTP envelope
sender, not necessarily the visible From address. Allowed senders bypass Junk
sorting; this is an exception, not proof of identity. Blocked senders also go
to Junk, so they remain recoverable. If a saved sender appears in both lists,
validation rejects the change. Rules take effect independently for each LMTP
recipient, including messages addressed to multiple mailboxes.

Learning is server-wide, backed by Redis. Both high-confidence automatic
learning and explicit mailbox corrections are enabled by the learning toggle.
Trash moves and deletions do not teach the classifier. The classifier needs a
corpus of both spam and legitimate examples before Bayesian classification
starts (the tested Rspamd package defaults to 200 of each); ordinary filtering
still works while it learns. It does not automatically change thresholds.

The page checks configuration fingerprints, Postfix parameters, service
status, Redis connectivity and Rspamd/LMTP listeners every 30 seconds while
open. It is not a background alert service. Rspamd refreshes its default remote
maps itself; package updates follow the server's existing OS update policy.

## Server integration

The first apply installs distribution packages for Rspamd, Redis, Dovecot
LMTP and Pigeonhole. Postfix scans through the loopback Rspamd milter and
hands virtual delivery to Dovecot LMTP. A global Sieve script applies each
mailbox's sorting rules, while IMAPSieve invokes bounded learning scripts.

Generated configuration targets **Dovecot 2.3** and Debian/Ubuntu package
layouts. It was integration-tested with Ubuntu 24.04, Dovecot 2.3.21 and Rspamd
3.8.1. Dovecot 2.4 is explicitly refused. The installer also refuses existing
Postfix content filters/milters, per-service filter overrides, custom virtual
transports, custom Rspamd configuration, or existing global Sieve hooks rather
than silently replacing them. Standalone SpamAssassin can remain installed,
but any active Postfix integration must be reconciled before enabling Rspamd.

The scanner listens on loopback; the learning controller uses a private Unix
socket owned by `vmail`. A separate `hostctl-spam-redis` service stores training
data in `/var/lib/hostctl-spam-redis`, accessible only to `_rspamd` through a
private Unix socket. Existing Redis services are left unchanged. This feature does not expose the
Rspamd controller as a web page. As with other Hostctl server features, the
service account uses the installation's existing `sudo systemd-run` access.
Python 3 is required on the server.

## Failure and recovery

Apply records a baseline, writes generated files atomically, validates
Rspamd/Dovecot/Sieve/Postfix, restarts the services, connects Postfix last, and
checks readiness. Dovecot restarts so existing IMAP sessions pick up the new
learning hooks; email clients may briefly reconnect. On failure it restores previous managed files and Postfix
parameters. Packages installed by apt remain installed. Mail delivery is
configured to continue if the spam scanner is temporarily unavailable.

Disabling and applying restores the original delivery parameters and managed
files, stops/disables Rspamd and the private Redis instance, and preserves Bayesian data. It does not replace
unrelated Postfix configuration, remove mail, or uninstall packages. Changes
to managed files outside Hostctl block apply/disable until reconciled.

Root-only state and backups are in `/var/lib/hostctl/spam-protection`. If an
apply process is interrupted, the page reports recovery is required. Run the
bundled `priv/spam_protection/manage.py recover` as root from the installed
release/source tree, inspect the mail services, then retry. If automatic
rollback fails, the recovery record is deliberately retained.

For a message's explanation, inspect `X-Hostctl-Junk-Reason` and
`X-Spamd-Result` in its original source. Learning scripts log completion or
failure under the `hostctl-spam` journal tag without logging message contents.
Rspamd's own logs contain its detailed training results; very short or already
learned messages may not add a new sample.

## Verification

Application and failure-path tests:

```sh
mix test test/hostctl/spam_protection_test.exs test/hostctl/spam_protection/config_test.exs test/hostctl_web/live/panel_live/spam_protection_live_test.exs
python3 -m unittest discover -s test/spam_protection -p '*_test.py'
mix precommit
```

A disposable Linux integration test validates configuration, executes Sieve
rules, delivers synthetic SMTP messages to two mailboxes, verifies removal of
forged spam headers, and confirms both spam and ham learning from IMAP actions:

```sh
mix run --no-start scripts/spam-test-bundle.exs
docker build -t hostctl-spam-test:local test/spam_protection
docker run --rm \
  --mount type=bind,source=/tmp/hostctl-spam-bundle.json,target=/bundle.json,readonly \
  hostctl-spam-test:local
```

The container exposes no host ports and mounts no real mailbox data.
