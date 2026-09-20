# Portainer Standard Agent

Administrators can open **Features → Portainer Agent** (`/panel/portainer`) to
install, inspect, retry, or remove the Hostctl-managed Standard Agent. Docker
must already be installed and running; install Docker through Features first if
needed. This update does not include the unfinished tenant/security migrations.

Enter the **exact version of your existing Portainer server**, an IPv4 listen
address belonging to this host, and the server's `AGENT_SECRET` if configured.
The default `127.0.0.1` accepts only local connections. For remote management,
prefer a private/VPN address reachable by Portainer. `0.0.0.0` exposes port 9001
on every IPv4 interface. Restrict network access to your Portainer server using
the host/provider firewall; this installer does not change firewall rules.

Then add a Docker Standalone environment in Portainer, choose Agent, and enter
the reachable address as `host:9001` without a scheme. Match agent and server
versions. A running agent is not proof of a successful Portainer connection.

References: [agent installation](https://docs.portainer.io/admin/environments/add/docker/agent),
[version matching](https://docs.portainer.io/start/upgrade/docker),
[agent authentication](https://docs.portainer.io/faqs/getting-started/how-does-portainer-secure-connectivity-to-and-from-agents-and-edge-agents).

## Permissions and limits

Portainer controls Docker and therefore can control the host. The fixed container
is named `hostctl-portainer-agent`, uses `portainer/agent:<exact-version>`, mounts
only `/var/run/docker.sock` and `/var/lib/docker/volumes`, and publishes port 9001
at the selected address. It does not add `--privileged` or mount `/` into the
agent. The Docker socket still gives the agent substantial authority.

The panel sends a bounded, versioned request over
`/run/hostctl-portainer/control.sock`. A dedicated root service accepts only the
Hostctl service UID, using Linux peer credentials; its only operations are
`portainer-install`, `portainer-status`, and `portainer-remove`. It accepts no
arbitrary executable, image repository, command, mount, or Docker argument.
Application contexts recheck the administrator's saved role on every operation.
The route uses the existing admin LiveView session and authenticated browser
pipeline. There are no public management endpoints.

The service runs root-owned code from `/usr/lib/hostctl-portainer`, installed by
the trusted installer/post-deploy step. It adds **no sudo rule** and does not add
the Phoenix user to the Docker group. Existing Hostctl privileges are unchanged;
the broader control-plane hardening remains separate work.

Ownership and the agent configuration are stored in root-only schema-versioned
JSON under `/var/lib/hostctl-portainer`. The optional secret is kept only there
and in Docker's container environment, never in panel settings or logs. Docker
administrators can inspect container environment variables. Broker logs contain
operation/request IDs, peer UID, action, duration and outcome, not payloads.

An existing container without the recorded random ownership label is rejected.
Retries verify the existing container instead of creating duplicates. A failed
start retains its ownership claim for retry. Removal targets only this managed
agent, retaining the claim and leaving all other containers and volumes alone.
To change an installed agent's version, address, or secret, remove and reinstall
it. After a timeout, refresh status before retrying: the server may have finished.

This first installer supports Linux Docker Standalone with the standard
`/var/lib/docker` data directory. Rootless Docker, custom data directories,
Swarm, Edge Agent, IPv6 bindings, and SELinux configurations requiring a
privileged container need separate setup. Docker installation itself is not part
of the agent operation.

## Installation and verification

The normal Hostctl installer and root post-deploy step install and start
`hostctl-portainer.service`. No agent container is launched until an administrator
submits the panel form. For a trusted checkout already containing this update,
the equivalent operator-only service installation is:

```sh
sudo bash priv/deploy/install-portainer-broker
sudo systemctl status hostctl-portainer --no-pager
sudo journalctl -u hostctl-portainer -n 30 --no-pager
```

Do not grant Phoenix sudo access to that installer. Existing deployment code and
root-writable configuration concerns are documented in the broader security work.

Validation includes LiveView authorization/form/action tests, a real Unix-socket
Elixir client test, and Linux Python tests for peer credentials, malformed frames,
strict operation validation, container collisions, tampered mounts, retries,
sanitized responses and secret-free command arguments. Docker command execution
is stubbed in the Python suite; connection to a real Portainer server is a separate
deployment acceptance check.

Standalone 0.16.0 validation: `mix precommit` passed all 350 tests; the Linux
broker suite passed all 12 tests, including real Unix peer-credential checks.
The systemd unit passed `systemd-analyze verify`. A local browser preview
verified the administrator page, unavailable-service message, and invalid-version
feedback. The release hook was checked with newline-free `start_erl.data`.
No production deployment or real Portainer server connection was performed.
