# Updating and recovery

## Docker image updates

From the Docker host, open the menu or a root command shell using the container
name shown by `docker ps`:

```sh
# Management menu
docker exec -it --user root <container-name> getbible
# Command shell
docker exec -it --user root <container-name> /bin/bash
```

Inside the root shell, run `getbible` commands without `sudo`. For example,
`getbible dashboard update` followed by `getbible dashboard status` updates and
verifies the installed dashboard. Use `exit` to return to the host for the
Docker image commands below.

Docker installations use the image's manager source. From the host directory
holding `compose.yaml`, select the desired numbered `GETBIBLE_IMAGE_TAG` in
`.env`, then:

```sh
docker compose pull
docker compose up -d
docker compose exec --user root getbible getbible doctor
docker compose exec --user root getbible getbible status
```

This replaces the whole system container and causes a service restart; allow
the configured graceful stop period. Mounted configuration, numeric account
identities, data, interpreters and saved runtime generations survive. After
restoring the saved services, `getbible-image-update.service` automatically applies
a new or previously unapplied image to the dashboard, telemetry and enabled
endpoints. It uses bundled dependencies, checks runtime candidates before
switching traffic, and preserves previous generations on failure. It does not
fetch or scan Bible source data, issue certificates or change public DNS.

`getbible status` reports the image release, last applied release and update state.
The persistent `/var/lib/getbible/state/image-update.conf` records `APPLIED_VERSION`
only when every required target is current. The per-target journal at
`/var/lib/getbible/state/upgrades.json` records desired/applied fingerprints,
serving generations and failed or interrupted attempts. Restarting an applied
image checks eligibility without redeploying unchanged targets. A successful
selected subset may leave the image `partial`; this is not an outage or a claim
that skipped changes were installed. Inspect the plan and retry from the root
container shell:

```sh
getbible update
getbible status
```

`getbible doctor` remains diagnostic; it does not apply updates. A replacement
image and manual Docker updates adopt the newest bundled patch of each runtime
endpoint's selected Python family, including MCP, without fetching packages.
The compatible offline bundle is checked before changing saved selections. Native ordinary
`update` retains the selected exact patch. Retained generations keep their exact
interpreter for rollback in both modes. Docker's `self-update` directs the
operator to the host image workflow instead of changing image code through Git.

Telemetry history remains in place. Before the collector starts, updates inspect
the stored schema version and apply supported versioned migrations, including
schemas 1 and 2 through schema 3, after a protective backup under `/var/backups/getbible/telemetry`.
Requests, events, metrics, retention records, metadata and ingestion cursors are
preserved. Database schema versions are independent of image releases and Bible
API versions; the stored database version determines the migration. The current
schema is unchanged; unknown or newer schemas remain intact and report a failure.
There is no update-time history reset. Bible source files remain unchanged.
Schema 3 prepares historical reporting summaries incrementally after startup;
the dashboard retries reports while their history is being prepared. This work
runs in the collector and does not redeploy public API workers.

`latest` follows accepted merges into `main`; it is not an automatic updater. Pulling and
recreating is still necessary. Numbered tags provide repeatability. Returning
to a previous image is different from runtime generation rollback: if a newer
image has already applied incompatible persisted configuration, restore the
matching backup as well. Keep a consistent, numeric-ownership-preserving
backup before updating; see [DOCKER.md](DOCKER.md).

## Update the manager script

This section applies to native installations.

When improvements are published, update the manager's checkout with one
command:

```sh
cd /opt/getbible/api
sudo ./getbible.sh self-update
```

The menu offers the same as **Update manager script** and exits after a
successful update. `self-update` fetches the checked-out branch's upstream
over the clone's own remote, using root's deploy key from `/root/.ssh/config`
(see [INSTALL.md](INSTALL.md#1-clone)), and advances the checkout by
fast-forward only. It updates the whole repository (script, libraries,
templates); the next invocation runs the updated code. It does not apply
configuration, install helpers, restart services or redeploy hosted domains,
and takes no domain argument. The management lock keeps other manager
commands out while it runs.

The update stops, changing nothing, if git is missing, the installation is
not a Git checkout, the checkout has local modifications or untracked files,
HEAD is detached, the branch has no upstream, or a fast-forward is not
possible; so do authentication and network failures. Resolve the reported
problem and run it again: the updater never discards local changes or merges
divergent history, and `--yes` does not bypass these checks. `sudo
./getbible.sh self-update --dry-run` reports what would be fetched without
contacting the remote.

## Apply changes to hosted domains

When you choose to apply the checked-out templates and application changes,
run the separate domain update operation. To roll out to one domain first:

```sh
cd /opt/getbible/api
sudo ./getbible.sh doctor
sudo ./getbible.sh update query.getbible.net
sudo ./getbible.sh status query.getbible.net
sudo ./getbible.sh update
```

Plain `update DOMAIN` applies that domain (every endpoint of it) from the
current checkout without fetching; `update` processes all registered domains
and reports failures. After trying one domain, plain `update` applies the same
checkout to the rest without fetching newer commits. Manager mutations are
locked to prevent concurrent commands from interleaving configuration changes.
Staged domains (see `NEW_SERVER.md`) are updated like the others and stay
staged: an update never requests a certificate or changes DNS for them. An
update rewrites every generated page and OpenAPI document; the ones an
operator has taken over are left alone (`PAGES.md`).

Explicit updates also install the current collector, dashboard and management
service code. The broker finishes accepted jobs and preserves their results
before restarting; issued credentials remain available until collected or their
existing one-use window expires. Saved settings and state stay outside the
checkout under `/etc/getbible` and `/var/lib/getbible`. Updating source never
replaces those values with the example configuration.
An unavailable telemetry collector or a reporting-specific backup/migration
failure is recorded as an incomplete management target, but does not prevent
independent selected API targets from proceeding. Unknown history is never reset. Use `dashboard
update` to refresh the dashboard and reporting services without redeploying
API domains, then `dashboard status` to verify the running release.

## Select targets and verify completion

```sh
getbible update --plan
getbible update --plan --json
getbible update --select
getbible update --target runtime/query.example.com/v2 --target mcp/mcp.example.com --yes
getbible update --target management --yes
getbible update --targets '' --yes
getbible update --all --yes
getbible update --retry --yes
```

Use the exact IDs reported by your plan: `management`,
`runtime/DOMAIN/vN` (or `root`), `mcp/DOMAIN`, and `static/DOMAIN`.
The menu and dashboard's **Upgrade targets** use this same controller. Changed
eligible targets are selected by default; clear the selection to perform no
work. A displayed plan is rechecked under the management writer lock before
activation, and stale plans must be reviewed again.

A static target means its nginx/sync software, generated documentation and
configuration, not a Bible data synchronization. Use `sync` explicitly for data.
Software/image application neither downloads corpus data nor changes public DNS,
requests certificates or modifies Cloudflare rules. Explicit access-policy and
go-live actions remain the way to change those settings. Missing saved TLS
material blocks that target while its prior routing is retained.

Each selected target completes independently. Skipped required targets stay
pending; failed targets preserve diagnostics and can be retried. A successful
explicit subset returns success even when unrelated changes remain pending.
A failed selected target returns failure, and a full `--all` application returns
failure if any required target remains unresolved. Serving health is reported
separately: a healthy retained generation does not make a rejected upgrade
successful. Unselected runtime siblings retain their generation. A domain shares
one nginx route, so applying one version may refresh the shared vhost/docs, but
it does not redeploy another version. Resource admission can refuse a selected
upgrade that cannot safely overlap live/draining workers; it does not silently
redeploy unselected neighbours to obtain capacity.

## Management release recovery

Management code, launchers, service templates and frontend assets are staged
under `/opt/getbible/management/releases`. Validation checks syntax/imports,
asset references, identity and service-readable permissions before selection.
The `current` link selects a complete generation; running processes resolve their
own release rather than importing a mixture of old and newly copied files.
The private activation journal and retained service definitions allow compatible
recovery after copy, startup, health-check or interrupted activation failures.
Unknown journal formats remain intact for inspection.

The database version is inspected before stopping the collector. A current
schema needs no stop or backup; supported migrations retain a durable snapshot.
Dashboard reads remain available while reporting migrates, though reports may
show temporary preparation/unavailability. A failed migration is rolled back by
SQLite and does not reset history. If a newer schema already committed, old code
that cannot read it is not restored: the status requires compatible forward
recovery instead. Reapplying the desired management target retries safely.

An unchanged management release keeps its original version/revision identity.
`running_latest` compares implementation fingerprints, not just the global image
number. There is no promise of zero interruption for a whole system-container
replacement; its shutdown/startup is distinct from a graceful runtime handoff.

## Choose the operation

| Operation | Result |
| --- | --- |
| Docker image replacement | Automatically applies the installed release to management services and enabled endpoints after restoring saved services; an already applied image skips refresh on restart. |
| `status` | Shows service state and, in Docker, image release, applied release and image-update state. |
| `doctor` | Diagnoses the installation without applying an update. |
| `self-update` | Native: fetches the current branch's upstream and fast-forwards the clean manager checkout. The next invocation loads the updated code; hosted domains are not applied. Docker: directs the operator to host image replacement. |
| `dashboard update` | Stages and validates management code/assets together, activates changed code and verifies the backend; unchanged code is not restarted. Compatible prior code/units are retained for recovery. API runtimes are not redeployed. |
| `update [DOMAIN]` | Uses the shared target planner. Without a domain, selects eligible changed targets; an interactive invocation presents a checklist. A domain restricts the scope to its targets and does not implicitly select management. Native retains the selected exact Python patch; Docker adopts the newest bundled patch of the selected family. |
| `update --plan [--json]` | Inspects relevant implementation/configuration, selected generation and serving readiness without changing services or upgrade state. |
| `update --target ID` | Applies only that target; repeat the option for multiple targets. `--targets ID,ID` is equivalent; `--targets ''` applies nothing. |
| `update --retry` | Retries failed/interrupted targets. A currently blocked retry reports failure rather than silently succeeding. |
| `update --force` | Explicitly allows fresh generations for selected unchanged targets. It is not needed for ordinary upgrades. |
| `capacity [--json]` | Reports measured usage, saturation, collector backlog/throughput and advisory limits without changing any setting. |
| `runtime DOMAIN update` | Rebuilds application dependencies and adopts the latest reviewed patch of each endpoint's selected Python family. `runtime DOMAIN v3 update` does it for one endpoint. |
| `runtime DOMAIN [vN] update --python 3.14` | Explicitly selects the catalog's current 3.14 patch and creates a new runtime release. An exact catalog patch is also accepted. |
| `runtime DOMAIN redeploy` | Starts a fresh deployment of every endpoint's current release and settings, rebuilding code only if its inputs changed. |
| `runtime DOMAIN [vN] set WORKERS 4` | Validates the endpoint's setting and activates a new generation; the running process receives the updated configuration. |
| `runtime DOMAIN [vN] rollback` | Activates the endpoint's retained previous code, interpreter and settings, preserving the domain's current access mode, quotas and tokens. |
| `version add DOMAIN v3` | Adds a version to a runtime domain as its own service (see `RUNTIME_ENDPOINTS.md`); `version default DOMAIN v3` makes it answer `/` and the short forms. |
| `sync DOMAIN v2` | Fetches and publishes the selected trusted static endpoint, then atomically changes its live symlink when needed. |

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
nor an nginx reload: an interrupted export is never published. Upstream content
is copied as committed, without a second JSON or checksum validation pass.

Unchanged code and configuration reuse their existing deployment. Hand-edited
managed files are detected against `/var/lib/getbible/ledger`: an interactive
update asks before replacing them; `--yes` keeps and reports them. A declined
nginx route change aborts the deployment and restores its prior routing, so
review and reconcile local edits before retrying. Backup sets are retained
under `/var/backups/getbible/`.

## Maintenance checks

After updating the manager checkout, run `doctor` and the per-domain `update`
commands above. Each endpoint keeps its selected managed Python version on
ordinary updates. Runtime updates use the candidate, readiness, routing and
rollback process described above; static updates preserve published releases
and endpoint keys while applying the current configuration.

Before updating a token-only endpoint behind Cloudflare, grant the connector
Cache Purge permission. The update disables shared caching and purges that
hostname's previously public content before activation. Missing permission or
a failed purge aborts the protected transition. See [CLOUDFLARE.md](CLOUDFLARE.md).

### Static endpoint deploy keys

Static deploy keys are per endpoint and repository URL. Reapplying a domain
preserves each endpoint's key when its URL is unchanged. A repository URL
change selects a separate key, while branch and source-folder changes retain
the existing key. Register a new repository key as read-only before testing
access and syncing:

```sh
sudo ./getbible.sh deploy-key api.getbible.net v2
# Register the displayed public key on v2's repository as a read-only deploy key.
sudo ./getbible.sh repo-access api.getbible.net v2
sudo ./getbible.sh sync api.getbible.net v2
```

Other endpoints keep their own keys and published data. Use `root` as the
label for a domain without version folders. Root's manager-update key is
independent. See [STATIC_ENDPOINTS.md](STATIC_ENDPOINTS.md) for the complete
workflow with different repositories on one domain.

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
checks do not establish an enterprise SLA. The source repositories remain authoritative; production
updates do not run corpus validation or introduce additional monitoring/load
tests. Maintain the host independently of the application.
