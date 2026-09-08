# Updating and recovery

Pull reviewed repository changes, then apply them to one domain first:

```sh
cd /opt/getbible/api
sudo git pull --ff-only
sudo ./getbible.sh doctor
sudo ./getbible.sh update query.getbible.net
sudo ./getbible.sh status query.getbible.net
sudo ./getbible.sh update
```

The menu also offers "git pull first, then update" and refuses to pull a dirty
checkout. `update DOMAIN` applies that domain (every endpoint of it); `update`
processes all registered domains and reports failures. Manager mutations are
locked to prevent concurrent commands from interleaving configuration changes.
Staged domains (see `NEW_SERVER.md`) are updated like the others and stay
staged: an update never requests a certificate or changes DNS for them. An
update rewrites every generated page and OpenAPI document; the ones an
operator has taken over are left alone (`PAGES.md`).

## Choose the operation

| Operation | Result |
| --- | --- |
| `update [DOMAIN]` | Applies checked-out templates, helpers, configuration, documentation and changed runtime code/dependency pins. Retains the selected exact Python patch. |
| `runtime DOMAIN update` | Rebuilds application dependencies and adopts the latest reviewed patch of each endpoint's selected Python family. `runtime DOMAIN v3 update` does it for one endpoint. |
| `runtime DOMAIN [vN] update --python 3.14` | Explicitly selects the catalog's current 3.14 patch and creates a new runtime release. An exact catalog patch is also accepted. |
| `runtime DOMAIN redeploy` | Starts a fresh deployment of every endpoint's current release and settings, rebuilding code only if its inputs changed. |
| `runtime DOMAIN [vN] set WORKERS 4` | Validates the endpoint's setting and activates a new generation; the running process receives the updated configuration. |
| `runtime DOMAIN [vN] rollback` | Activates the endpoint's retained previous code, interpreter and settings, preserving the domain's current access mode, quotas and tokens. |
| `version add DOMAIN v3` | Adds a version to a runtime domain as its own service (see `RUNTIME_ENDPOINTS.md`); `version default DOMAIN v3` makes it answer `/` and the short forms. |
| `sync DOMAIN v2` | Fetches and verifies the selected static endpoint, then atomically changes its live symlink when needed. |

See `runtime versions` for the reviewed interpreter catalog. New upstream
Python releases become eligible after a repository change updates
`src/python/distributions.lock`; deployment never queries an unpinned latest
interpreter feed. Application dependency changes belong in the kind's pinned
`requirements.txt`. Built releases retain Python provenance and `packages.lock`.
Host Python updates cannot replace managed runtime Python or its standard
library. Kernel, glibc, systemd and nginx updates remain host maintenance.

## How an update preserves service

Runtime releases build beside the live release, for every endpoint of the
domain that needs a change. Each candidate gets a separate environment,
systemd service and socket. It must serve real scripture through `/readyz`;
search also passes its search probe before traffic changes. nginx
configuration is backed up, validated with `nginx -t`, and gracefully reloaded
once for all of them.
The old backend stays alive until the recorded pre-reload nginx workers exit;
PID start times guard against PID reuse. Retirement runs independently of the
CLI. Allow temporary memory for both generations and their warm-up work.

Preparation failures leave the old runtime serving. Activation failures restore
the prior routing and deployment state; a failed routing recovery retains
processes and reports the failure for inspection. nginx is never restarted by
the deployment pipeline. Static data rotation needs neither a runtime restart
nor an nginx reload: incomplete or invalid exports are never published.

Unchanged code and configuration reuse their existing deployment. Hand-edited
managed files are detected against `/var/lib/getbible/ledger`: an interactive
update asks before replacing them; `--yes` keeps and reports them. A declined
nginx route change aborts the deployment and restores its prior routing, so
review and reconcile local edits before retrying. Backup sets are retained
under `/var/backups/getbible/`.

## Migrate an existing installation

Run the same pull, `doctor`, and per-domain `update` commands above. Existing
single-service runtime installations are captured as rollback generations;
the first successful update moves them to owned Python and isolated deployment
generations. An existing exact managed Python version remains selected on
ordinary updates. Token-map permissions and per-request expiry maps migrate
with the nginx configuration.

A runtime domain recorded before endpoints had their own records (a `VERSION`
key and the service settings in `endpoint.conf`) gets its endpoint record
(`versions/<version>.conf`, `LAYOUT=legacy`) the first time the tool looks at
it: the settings are copied into the record and every path, unit and socket
stays where it is, so nothing running is moved or restarted by the migration
itself. The next apply proceeds as any other. Versions added afterwards get
their own paths (`/opt/getbible/<kind>/<version>/`). Static domains gain a
page per endpoint and `versions.json` on their first update; nothing about
their data changes.

Before updating a token-only endpoint behind Cloudflare, grant the connector
Cache Purge permission. The update disables shared caching and purges that
hostname's previously public content before activation. Missing permission or
a failed purge aborts the protected transition. See [CLOUDFLARE.md](CLOUDFLARE.md).

## Recovery and operational checks

```sh
sudo ./getbible.sh status query.getbible.net
sudo ./getbible.sh logs query.getbible.net journal v2 --lines 100
sudo ./getbible.sh runtime query.getbible.net v2 rollback
sudo nginx -t
```

Use the rollback command instead of manually changing `current` or restarting
a historical unit name: code, settings, service names and sockets must agree.
If automatic routing restoration reports failure, inspect the nginx error and
backup sets before retrying; retain the old generation and interpreter files.
Manual nginx recovery must validate configuration before `systemctl reload
nginx`. Static data recovery can republish a corrected source commit with
`sync DOMAIN v2 --force`; retained releases also permit an operator-controlled
atomic symlink restore while holding that endpoint's sync lock.

CI exercises supported Python families, real nginx/Gunicorn, actual systemd
service users, upgrades, failure recovery and a request-load smoke test. These
checks do not establish an enterprise SLA. Before production, test the actual
Bible corpus and expected concurrency, monitor HTTPS query/search responses,
verify backups and recovery on a separate host, and establish capacity and
host-maintenance procedures.
