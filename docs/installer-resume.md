# Resuming an installation

The installer saves your choices before preflight and saves generated database
passwords before package operations. If a run fails, fix the reported problem
and retry on the same machine:

```sh
sudo bash install.sh --resume
```

The wizard is skipped unless requested. The installation plan and confirmation
still appear; add `--yes` to skip confirmations. To review saved choices in the
wizard, use:

```sh
sudo bash install.sh --resume --interactive
```

Explicit command-line options override saved choices regardless of where
`--resume` appears. Boolean skip flags, `--cloudflare`, and `--reconfigure` accept
`=false` to turn off an earlier selection:

```sh
sudo bash install.sh --resume --branch=main --skip-php=false
sudo bash install.sh --resume --cloudflare=false --skip-certbot=false
```

Saved choices include the domain, installation directory, repository and branch,
database flavor, skip flags, logging/verbosity, generated passwords, and generated
application secrets. `--yes` and `--interactive` apply only to the current run.
`--verbose=false` disables previously saved verbose output; `--log=` clears a
saved log destination. Normal invocation without `--resume` starts from defaults
and supplied options, replacing the saved choices.

State is stored in `/var/lib/hostctl-installer`, with directory permissions `0700`
and choices file permissions `0600`. It contains credentials: keep it on the VM
and do not commit or share it. The state file is parsed as data, never executed
as shell code. A lock prevents concurrent installer runs. Successful installs
retain the state for later retries too.

For a nonstandard state location, use the same override on every run:

```sh
sudo env HOSTCTL_INSTALL_STATE_DIR=/root/hostctl-install-state bash install.sh --resume
```

Resume reruns checks and retries the installation; it does not jump past entire
phases based on a completion marker. APT and installed-package checks reuse
existing work, while complete Elixir/key downloads remain cached under the state
directory. Partial downloads are retried. Builds keep the existing source build
cache, but still run the normal build steps unless `--reconfigure` is selected.

This does not resolve the underlying installation error. For example, an
unsupported Ubuntu package repository must be corrected before retrying.
Installations attempted with older scripts have no saved state: use the updated
script and supply your choices once to enable subsequent resumes.

Run the portable state/argument/download regression tests from the repository:

```sh
python3 -m unittest discover -s test/installer -v
bash -n priv/deploy/install.sh
```

These tests do not install packages or start services. Real `flock` behavior,
package installation, and service retries still require a Linux VM test.
