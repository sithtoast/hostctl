# Docker domain and subdomain proxies

Administrators can use **Docker → Proxies** to expose a container through Hostctl's
Nginx web server. The existing `/panel/docker` route remains in the authenticated
browser scope and `require_admin` LiveView session; customers cannot manage
server-wide containers or mappings.

1. Publish the container's application port on the hosting server. Prefer binding
   it to loopback, for example `127.0.0.1:8080:80`. The app must be reachable from
   Nginx at `127.0.0.1:<published port>`.
2. Select an active web-hosting domain and a container. Enter `app` in Subdomain
   for `app.example.com`, or leave it blank for `example.com` and its `www` alias.
   A separate filesystem subdomain record is not required.
3. Use `/` for the entire hostname or `/app` for a prefix. A prefix mapping redirects
   `/app` to `/app/` and removes `/app/` before forwarding to the application.
4. Choose the **published host port** and the container's HTTP or HTTPS protocol.
   This is independent of the browser-facing certificate. HTTPS upstreams are
   local loopback connections and accept self-signed container certificates.
5. Enable **WebSocket support** when needed. Existing mappings remain enabled by
   default. The switch beside each saved mapping changes the setting and applies
   Nginx immediately. Disabled mode clears both Upgrade and Connection headers.
6. Point the hostname's A/AAAA records to this server using your DNS provider.
   This form does not publish DNS. Browser HTTPS requires an active certificate
   with wildcard subdomain coverage on the selected parent domain; otherwise the
   subdomain serves HTTP. A one-label subdomain matches that wildcard coverage.

Choose the server's actual web application port, not a management-agent or other
non-HTTP port. Container selection helps fill the port; the saved route uses the
fixed loopback host port, not the container's changing private IP address.

Separate hostnames can use the same URL path. `www` is reserved for the domain's
existing alias. Suspended subdomains, separately hosted hostname collisions and
S3 mappings that already occupy the target are rejected. An existing active
filesystem subdomain can receive a proxy; removing the proxy restores its normal
filesystem configuration. Existing S3 precedence and main-domain mappings remain
unchanged. Parent-domain suspension still suspends the site.

A saved mapping is not proof of successful deployment. If Nginx fails to apply,
the panel reports the failure and retains the desired mapping. Fix the web server
and use **Retry apply**, or **Reapply mappings** after a failed removal. DNS,
certificate installation and application reachability must also be correct.

The migration preserves existing mappings as blank-subdomain HTTP routes with
WebSocket support enabled. After multiple hostnames share a path, an old-version
rollback requires resolving those duplicates before restoring its unique index.

## Local validation

`mix precommit` passes 363 tests, including context authorization, hostname and S3
conflicts, independent Nginx vhosts, certificate coverage, form port retention and
persistent WebSocket switching and apply-failure reporting. The existing HTTP mappings keep their defaults.

For the disposable Linux forwarding test, run
`mix run --no-start scripts/docker-proxy-test-config.exs`, mount the resulting
`/tmp/hostctl-docker-proxy.conf` at `/proxy.conf`, and execute
`test/docker_proxy/integration.py` in the isolation test image. This tests real
Nginx HTTP and HTTPS upstreams, root routing, prefix stripping, a WebSocket
handshake and echo, and disabled upgrade headers without an external network.
It does not validate production DNS, certificates or the user's containers.

The local browser flow was checked at desktop and mobile widths using synthetic
Docker inventory, including creation, port preservation and the saved switch.
