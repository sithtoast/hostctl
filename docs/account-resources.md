# Account resources and operator lookup

September 12, 2026. The user selected a resource view plus shell lookup to make
process ownership easy to identify while preserving existing Linux names.
Recognizable OS usernames remain a possible future SSH design decision.

## Administration page

Open **Administration → System & access → Account resources** (`/panel/resources`).
The route uses the existing `:require_admin` LiveView session within the
`[:browser, :require_authenticated_user]` pipeline. Context functions also
require an admin scope. Clients and resellers cannot inspect server-wide processes.

The page shows Linux process name/PID, username/UID, owning account and its
domains, CPU lifetime average and resident memory. It sorts by CPU and then
memory, shows at most 500 matches, and searches name, email, domain, Linux
username, UID, PID and process name. Refresh reads a new snapshot. Sampling runs
asynchronously; failed reads clear the table rather than present stale usage as
current. Metrics are not stored and there is no background polling service.

Attribution uses the persisted numeric UID, with an additional Linux username
consistency check. A mismatch is flagged without assigning a customer. Retained
identities identify the original account number after its login is deleted.
Processes without a matching reservation display as system/shared services.
In particular, legacy `www-data` processes cannot safely be assigned to one
customer. A domain list means the owner's domains, not proof that a particular
process is handling requests for one of those domains.

Only process name (`comm`) is collected, never command arguments or environment
variables. No process termination, suspension, ownership change or OS login
configuration is included.

## Shell lookup

On a release installed with this change:

```bash
sudo /opt/hostctl/bin/account-owner --user hc_5
sudo /opt/hostctl/bin/account-owner --uid 1005
sudo /opt/hostctl/bin/account-owner --pid 1234
```

The command emits JSON with account name/email, domains and reserved identity.
PID lookup includes the sampled process and its attribution. Unknown UIDs/users
and missing PIDs return a nonzero exit status; a shared process is returned with
an explicit shared attribution and no owner. A PID is only a point-in-time
observation and can exit or be reused afterward.

Root is required to read `/etc/hostctl/env`. The wrapper loads it privately and
uses release `eval`; only the repository starts, without web, upload or backup
workers. It does not require the panel to be running. Source installations can
use `mix hostctl.account.owner` with the same flags and the intended database
configuration. UID and username database lookups work without Linux; process
lookup and page metrics require Linux.

## Metric limits and SSH direction

`ps` CPU percentage is averaged over the process lifetime, not a short-interval
CPU sample. A sudden spike in a long-lived process can therefore be understated.
100% represents one CPU core. RSS includes shared pages and is not exclusive
account memory. Process visibility depends on the service's `/proc` permissions;
restricted visibility may omit processes. This is a troubleshooting attribution
view, not resource limits, historical billing metrics or a replacement for top.

Friendly Linux names would make SSH usernames and shell prompts more convenient.
They are not required for SSH. Future SSH access still needs explicit key, shell,
access and isolation policies: current hosting identities remain locked and this
feature does not enable SSH/SFTP. Actual renaming would require the managed
UID/GID-preserving migration assessed in `cloudflare-sync-follow-up.md`.

## Validation and rollout

- Context/LiveView tests cover owner/domain mapping, admin-only access, search,
  refresh, stale-data clearing, shared processes, UID/name mismatch, retained
  identities, all three lookup forms and strict parser/argument handling.
- The actual Mix command was run against a disposable preview database.
- The parser processed 204 lines from a read-only Linux `ps` snapshot on the
  Ubuntu 26.04 server. No command arguments or environment data were collected.
- An isolated local Phoenix server with synthetic accounts/processes was checked
  in the browser: navigation, populated table, account filtering and refresh.
  This does not prove attribution or process visibility in the installed service.
- Asset compilation and `bash -n rel/overlays/bin/account-owner` passed. The copied
  local Tailwind binary needed its ad-hoc signature repaired before it could run;
  only the ignored build cache was changed.

Build/deploy the branch's latest release using the proposed maintenance procedure
in `cloudflare-sync-follow-up.md`; the new shell wrapper is included by the
release overlay. There are no database migrations. After deployment, compare a
known tenant PHP PID/UID with the page and all three shell lookup forms, verify
its account domains, and check that a shared process remains unattributed. Verify
client/reseller access is denied. No installed Linux identities should change.
