# Domain statistics and Plesk completion follow-up

September 12, 2026. Implement this work in the new task; this handoff records
approved scope and investigation, not completed features.

## User requests and decisions

- Merge the completed Cloudflare/resource/security work into the default branch.
  Done: local `main` at `/Users/wmh/Dev/hostctl` was clean and fast-forwarded from
  `feabc3b` to `68eb2c4a98c5bb3ae39814819528f26c8d9773ed`. No push occurred.
- The later SSH/account-name possibility is already recorded in
  `docs/account-resources.md`, especially "Metric limits and SSH direction".
  Preserve stable `hc_<owner_id>` identities. SSH/SFTP remains a separate feature.
- Add domain traffic statistics: see where visitors come from and what they access.
  The user explicitly chose **GoAccess plus preserved Plesk history** after this
  question: "GoAccess for new traffic, with Plesk's old AWStats reports kept as
  historical reports and any retained access logs used to rebuild detailed history."
- Fix the last Plesk import page: the user says it never updates to completion
  and just directs them to logs.
- The user approved moving this work to a new chat and/or branch. Branch
  `codex/domain-stats-import-progress` was created from `68eb2c4`. No feature code
  has been modified yet. Continue implementation, validation and local commits;
  do not stop at another plan or repeat the design question.

## Required starting context

Read AGENTS.md and `docs/development-memory.md`. Follow the Phoenix conventions,
authenticated scopes, LiveView streams and `mix precommit`. Preserve unrelated
changes. No public Cloudflare writes, Linux account rename, production import,
GitHub push or live service interruption is part of this local feature work.

Solid is `william@192.211.55.181`, using the explicit SSH key documented in
development-memory (the old `hostctl-dev` alias points elsewhere). Sudo is
interactive. The previous corrected update was staged at
`/tmp/hostctl-followup-68eb2c4/apply`; the user replied "nice!", but no successful
installation output or running-commit verification has been supplied since that
staging. Recheck before describing the installed version as confirmed.

The previous patch passed 291 tests, a clean production build on Solid and
`mix hex.audit` with no retired/advisory packages. See
`docs/security-build-follow-up.md`. Keep `assets.deploy`'s leading `compile` and
the portable MDEx native artifact configuration: Solid's virtual CPU lacks AVX/FMA.

## Import completion investigation

Main files:

- `lib/hostctl_web/live/panel_live/plesk_import.ex`
- `lib/hostctl/plesk/importer.ex`
- `lib/hostctl/plesk.ex`, `lib/hostctl/plesk/migration.ex`
- `lib/hostctl/hosting/upload_job.ex`, `lib/hostctl/upload_worker.ex`
- `test/hostctl_web/live/panel_live/plesk_import_test.exs`

Verified code findings:

1. `render_import_progress/1` currently always leaves the text "Verification:
   not recorded. Check the destination website, data, and mail delivery." A
   successful restore result only changes configuration to "Finished — review
   transfers"; there is no overall terminal completion summary or category
   error detail on this final step. Detailed results are on the mapping step.
2. The LiveView does subscribe to `upload_jobs` and handles `:upload_progress`
   by reloading jobs. `load_upload_jobs/1` filters by the logged-in **admin's**
   user ID and truncates to 20 rows. However, `launch_restore_task/5` passes
   `scope.user.id` for the **target owner** into the importer and upload jobs.
   Therefore imports into customer accounts can disappear from the admin's
   transfer view. This is a concrete code-level defect; it has not yet been
   reproduced against the user's running import.
3. The importer schedules background per-target S3 jobs and returns configuration
   results before uploads finish. `restore_target_web_files/11` discards the
   returned job ID; job metadata currently contains only `label`. There is no
   import-run identifier tying terminal results to precisely their jobs.
4. Task results arrive as `{ref, {:restore_result, domain, result}}`; the handler
   clears task/progress maps and stores results but does not explicitly reload
   jobs. `Task.async` links tasks to the LiveView; exception/disconnect behavior
   and saved/reloaded migration status deserve regression coverage.
5. Saved migration status currently treats every `{:ok, result}` as completed,
   ignoring pending/failed transfers. Serialization retains domain status and
   categories, but no run ID. Avoid falsely calling transfers or live website/
   mail acceptance verified based only on configuration success.

Suggested implementation, subject to source review: correlate jobs with an
import-run ID or explicit returned IDs, persist that correlation in saved results,
and query them through an admin-scoped context regardless of target owner. Avoid
mixing jobs from prior attempts or silently dropping the 21st job. Show live
queued/running/paused/failed/completed transfer status, category totals/errors and
a clear terminal import summary. Keep manual website/mail acceptance separately
labeled. Refresh/reconnect must not falsely claim success. Use meaningful tests
for cross-owner job visibility, completed/failed uploads, local-only completion,
partial category results and unrelated/old jobs. Do not assign credentials to a
new public stats/job response or expose secrets in logs.

## Domain statistics investigation and direction

Official sources checked September 12, 2026:

- [Plesk's AWStats retirement and GoAccess recommendation](https://support.plesk.com/hc/en-us/articles/39869614105111-Why-was-AWStats-deprecated-what-tool-replaces-it-and-what-happens-to-existing-servers-and-domains-that-still-use-AWStats)
- [GoAccess manual](https://goaccess.io/man): persistent/incremental processing,
  `--persist`, `--restore`, `--db-path`, HTML/JSON reports and log formats.
- [Plesk historical AWStats reconstruction](https://support.plesk.com/hc/en-us/articles/12388113004439-How-to-regenerate-AWStats-web-statistics-using-domain-logs-for-previous-months-in-Plesk)
- [Plesk statistics and log layout](https://doc.plesk.com/en-US/onyx/advanced-administration-guide-linux/statistics-and-logs.68646/)

AWStats is no longer actively maintained; Plesk recommends GoAccess starting
with Obsidian 18.0.77. Do not install a new AWStats CGI service. Preserve legacy
reports/history, and rebuild from retained raw access logs where possible.
Aggregated AWStats history cannot be assumed to contain recoverable individual
requests; missing logs mean some history cannot be reconstructed in GoAccess.

Existing integration points:

- `lib/hostctl/web_server/nginx.ex` writes per-host access logs to
  `/var/log/nginx/#{log_name}.access.log` across several vhost modes. Inspect all
  naming/SSL/subdomain/proxy cases before deriving inputs. No stats integration
  exists yet. Check actual log format and trusted proxy/client-IP handling.
- `lib/hostctl/feature_setup.ex` is the optional feature registry with apt package
  installation and progress reporting. GoAccess could be an optional feature.
- `priv/deploy/install.sh` gives Hostctl's systemd service
  `SupplementaryGroups=adm`, which may permit reading Nginx logs; verify real
  permissions and logrotate behavior. Do not grant tenants raw global log access.
- `lib/hostctl_web/live/domain_live/show.ex` loads a domain through owner scope
  (or an explicit admin lookup); use the same account/domain authorization for
  stats and report-download endpoints. Place new LiveViews in the existing
  authenticated session and explain scope/pipeline choices to the user.
- `lib/hostctl/plesk/ssh_probe.ex` has an inventory category allowlist, and the
  Plesk import UI/importer have separate data/restore category lists. Statistics
  are not in them yet. Current per-domain config/DB backup commands deliberately
  use `-exclude-logs`; these backups do not automatically provide traffic history.

Implementation needs a usable per-domain stats view for requested URLs, referrers,
traffic/visitors and available geographic information. Distinguish referrers from
geography, bot hits from estimated visitors, and absent/unknown data from zero.
GeoIP needs a supported data source; do not promise country accuracy when only
Cloudflare/proxy addresses are logged. Log analytics cannot see CDN cache hits
that never reach this server. Surface practical limitations concisely in the UI.

Use GoAccess's actual documented incremental behavior. Validate repeated refresh,
rotation and historical-log overlap to avoid double counting; keep imported
history separate where totals cannot safely merge. Reports and archived logs
must stay private and domain-scoped, outside public document roots. Treat imported
HTML as untrusted: use sanitization or isolated sandboxed serving, never same-origin
executable imported HTML. Reject symlinks/traversal/archive escapes. Do not run
Plesk-provided executable configuration as part of importing history.

No specific stats architecture beyond GoAccess plus preserved history was approved;
choose routine implementation details autonomously. Finish and test the import
completion defect alongside the feature, update this handoff, and commit locally.
