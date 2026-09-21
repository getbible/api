# Private management dashboard

The dashboard adds live and historical traffic reports, resource and translation
cache inspection, and the manager's administrative operations. React, Bootstrap
and Apache ECharts are bundled with the release; opening the dashboard does not
download a frontend library or install Python packages. The dashboard runs as
`getbible-dashboard`, separately from the public runtime workers, behind nginx.

## Enable access

For Docker, launch the menu from the host with
`docker exec -it --user root <container-name> getbible`. To enter commands, use
`docker exec -it --user root <container-name> /bin/bash` and run the `getbible`
commands below directly, without `sudo`. The container name is shown by
`docker ps`.

Configure Telegram through **Settings > Telegram** or the deployment environment.
Then use **Management dashboard** in the main menu, or:

```sh
getbible dashboard password set
getbible dashboard enable dashboard.example.com
getbible dashboard status
```

Use a separate hostname from every API domain. External TLS uses the existing
trusted HAProxy configuration and HTTPS certificate at the terminator. Native
managed TLS requires a certificate and supports explicit validation selection:

```sh
getbible dashboard enable dashboard.example.com --cert dns-cloudflare
```

Explicit activation can apply the configured default Cloudflare mode to this
hostname. Its rules always bypass shared caching. Container recreation restores
the local dashboard route, identities and enabled services; it does not issue a
certificate or modify DNS. API domains continue to use their existing independent
deployment and go-live workflows.

The equivalent environment settings are:

```dotenv
GETBIBLE_DASHBOARD_DOMAIN=dashboard.example.com
GETBIBLE_DASHBOARD_ENABLED=true
GETBIBLE_DASHBOARD_SESSION_DAYS=30
GETBIBLE_DASHBOARD_IDLE_SECONDS=60
GETBIBLE_DASHBOARD_TOKEN_SECONDS=60
```

Environment values are authoritative. Leave `GETBIBLE_DASHBOARD_ENABLED` and the
domain empty to manage them from the menu; the saved/default enabled state starts
as false. An explicit environment value of false prevents the CLI from enabling
the dashboard until that override is changed. Settings changes reload the
dashboard configuration with SIGHUP. `dashboard apply` and `dashboard update`
install the current manager's dashboard files, restart its backend, and verify
the running release. Saved authentication sessions are preserved.

Native installations use the same built-in settings without requiring Compose
or an environment file. Run these commands as root through `./getbible.sh` from
the manager checkout. Saved settings live under `/etc/getbible`; boot preparation
regenerates temporary service settings before the collector and dashboard start.
`self-update` fetches manager source, and a subsequent `update` applies it to the
installed management services and API domains. Docker receives manager updates
from a replacement image, which automatically refreshes the dashboard, telemetry
and enabled endpoints after restoring the saved services. Restarting an already
applied image skips the refresh. `getbible status` shows image application state;
`getbible update` retries or reapplies the release.

To update only the dashboard and its reporting services, run
`getbible dashboard update`, then `getbible dashboard status` from the root shell
(use `./getbible.sh` in the native manager checkout).
The status includes `manager_release`, `installed_release`, `serving_release`
and `running_latest`. The last value is true only when all three match; it
compares against the local manager, so fetch native source with `self-update`
or replace the Docker image first. The dashboard-only update command does not
redeploy public runtimes.

If reporting is unavailable, inspect
`journalctl -u getbible-telemetry.service -n 80 --no-pager` from the root shell.
The dashboard retries temporary storage failures while a viewer remains active
and reports permission, disk, and incompatible-schema errors separately.
Reporting history remains in place. Before the collector starts, updates use the
stored schema version to migrate supported older history through schema 3,
with a protective backup under `/var/backups/getbible/telemetry`. Records and
ingestion cursors are preserved. The current schema needs no work;
unknown or newer schemas remain intact and are reported for inspection. Updates
do not reset history or reread Bible source data.

The initial password is an undisclosed random value; set or reset it through the
CLI before the first login. Passwords are hashed and never stored in plaintext.
An automated password change can use stdin instead of process arguments:

```sh
getbible dashboard password set --stdin < /root/dashboard-password
```

## Sign-in and recovery

After a correct password, the configured Telegram chat receives a long, random,
single-use code. Enter it within the configured challenge window, normally sixty
seconds. A failed Telegram delivery does not start a challenge. Three consecutive
wrong passwords block the client IP. A wrong, expired or abandoned issued code
also blocks that IP. Recovery is deliberately available only through the CLI/menu:

```sh
getbible dashboard blocks
getbible dashboard unblock 203.0.113.10
getbible dashboard sessions
getbible dashboard sessions revoke SESSION_ID
getbible dashboard sessions revoke all
getbible dashboard password reset
```

Reset generates and displays a new password once. Setting or resetting a password
revokes sessions and pending challenges. Session cookies are Secure, HttpOnly and
SameSite, and expire after thirty days by default. Closing a browser or sleeping
the reporting engine does not revoke its session. Clearing the site's cookies,
expiration or server-side revocation requires sign-in again. Browser cache refresh
does not revoke authentication.

nginx overwrites the dashboard's client-address header using its verified
`$remote_addr`. In external TLS mode only configured proxy peers can provide
forwarded identity. Configure HAProxy to overwrite its forwarded address from a
verified Cloudflare connection; do not trust arbitrary public headers. IP blocking
affects every person sharing that public address, so keep CLI access available.

## Live reports and retained history

The 24-hour, seven-day and 30-day reports use exact hourly summaries with raw
records at the selected range boundaries. Charts covering at least a day use
hourly or coarser intervals; totals still respect the exact selected dates.
After an update, existing history is prepared incrementally while collection
continues. A report that needs unfinished historical summaries displays its
preparation state and retries automatically. No manual reset is needed.

Overview totals and history charts load independently. Fixed historical ranges
refresh when dates or filters change, or when **Refresh all** is selected. **Live**
reports refresh after the previous request completes. Resource charts request
only resource samples, without rebuilding traffic reports. A bounded in-memory
cache shares identical concurrent reports and invalidates when history changes.

The traffic collector runs continuously, independently of dashboard viewers.
Nginx and runtime events enter the canonical local telemetry database, including
request criteria, address, status, timing and token authentication state, with
credentials excluded. Requests served entirely from a CDN do not reach this origin
and cannot appear in origin traffic reports.

Live views issue authenticated heartbeats. Reporting workers initialize on demand
and drain after the last viewer has been absent for sixty seconds. The lightweight
authentication/activation service remains available, while traffic collection,
health sampling, alerts and already-started administrative jobs continue. A
Telegram notice reports when the reporting engine has gone to sleep. Suspended
browser tabs can stop heartbeats and wake again on their next request.

History offers arbitrary date ranges, endpoint and request filters, traffic and
latency charts, top queries/references/books/translations, and detailed event
tables. Retention is bounded by both `TELEMETRY_MAX_GIB` and
`TELEMETRY_RETENTION_DAYS`; zero days uses the size limit alone. The oldest records
are pruned first. A six-month date selector does not guarantee six months of
records fit in the configured disk allowance; the actual retained range and gaps
are shown. Change retention from **Logs > Change retention** or:

```sh
getbible settings set TELEMETRY_MAX_GIB 50
getbible settings set TELEMETRY_RETENTION_DAYS 180
```

The collector reloads its effective settings file without a process restart.
The older log-rotation size/count settings do not control canonical traffic
history. Diagnostic views and exports use the same stored telemetry.

Translation, search, scripture-reference and book rankings show successful
usage. Search rankings are scoped to search endpoints; reference rankings are
scoped to query endpoints. Selecting a ranking keeps its exact scope when
opening Traffic. Failed and unrelated requests remain available in Traffic,
endpoint totals and status filters. See [stored classification](LOGGING.md#stored-request-classification).

**Audience** lists referrers and user agents separately, with counts and search
fields. Select an entry to inspect its requests; its exact filter appears in
Traffic alongside endpoint, version, status, translation and request filters.
Traffic's free-text search finds paths, query text, referrers, user agents,
addresses and other stored request fields without opening each detail row.

**Translations** first shows one row per resident translation within each
runtime endpoint. Query chapter counts, search corpus/index counts and
translation snapshots are shown separately, along with worker coverage and
warm readiness. Select a translation to inspect individual workers, including
workers without resident data. The warm selector and disk inventory indicate
what is already warm, partially resident, stale or not in memory. Configured
startup warming is shown separately from current residency. Counts and cache
estimates are per-worker values or ranges, never a sum presented as unique
physical memory. Missing worker reports remain explicitly unknown.

## Administration and storage

The operation catalogue covers domains, endpoints and repository synchronization,
runtime deployments and rollback, resource settings, cache warm/drop/reload,
access modes, origin limits and tokens, certificates, pages/icons, Cloudflare,
Telegram, diagnostics, system maintenance, and dashboard sessions. Operations
requiring the Docker host, such as replacing its container image, retain their
host-side boundary and instructions.

**Manage** follows the CLI's menu hierarchy: choose a section, a domain when
needed, then its endpoint or settings group and an action. Breadcrumbs return
to previous levels. Current saved settings are shown with the selected target;
the same typed operation catalogue and validated CLI commands perform changes.

For query or search deployment, choose the runtime kind, then **API version**
(`v2` or `v3`) and **Local Bible source**. The source list follows the selected
version and shows available static scripture folders; selecting v3 lists v3
sources. A custom local parent root may also be entered and must contain the
selected version's folder. Sync that static endpoint before deployment.
To extend an existing domain, open its endpoint actions and add runtime version
`v3`; v2 keeps its own service and settings. Choose the default endpoint
separately to direct unversioned requests to v3.

The browser submits named operations and typed fields to a local root broker. It
does not submit arbitrary shell commands or receive a Docker socket. Each job has
progress, a durable result and an operator/session audit reference. Destructive
operations require explicit confirmation. Jobs continue if every dashboard tab
closes. A broker restart marks interrupted work for inspection and never silently
replays a potentially destructive command.

Jobs distinguish queued, waiting for the management lock, running and finished
states. An open interactive CLI menu holds that lock for its session; close an
idle menu to let a waiting dashboard job proceed. The original CLI process
waits and acquires the lock once, so a failed operation is never blindly retried
after it may have changed the server. Ordinary CLI timeout behaviour is retained.

New API bearer tokens are displayed only to the issuing session through an
explicit reveal action for up to five minutes. Their plaintext is never written
to the job database or traffic logs. Copy a token when it is issued; if it is lost,
revoke it and issue another one.

Custom documentation and OpenAPI can be edited inline. Favicon/logo uploads are
limited to one MiB, and custom UTF-8 documents to 128 KiB. The broker stages them
under a root-owned import directory and invokes the same validated CLI page
operations. Existing server-file imports are confined to
`/var/lib/getbible/imports` or `/var/www/getbible`, with symlinks and traversal
rejected. This prevents publishing private server files. A local root operator
retains the CLI's broader file-management ability.

Storage reports account for allocated blocks, deduplicate hard links and show the
mounted data, runtime, cache, log, page and backup components. `STORAGE_MAX_GIB`
provides conservative application admission checks for new static publications.
It is not a hard quota on a Docker bind mount: repository fetches and other writers
still require a host filesystem quota for a strict physical cap. The serving and
rollback corpus generations are never deleted to satisfy telemetry retention.

Actual process/container memory is distinguished from per-translation memory
estimates; shared corpus pages cannot simply be summed across workers. CPU
temperature is shown only when the host exposes a readable sensor.

## Service boundaries and verification

- `getbible-telemetry.service`: continuous ingestion and lightweight health data.
- `getbible-adapt.timer`: regular allocation and publication checks.
- `getbible-storage.timer`: independent metadata-only disk accounting when a
  storage budget is enabled. Long-running deployments cannot delay this sampler.
- `getbible-dashboard.service`: unprivileged authentication and on-demand reports.
- `getbible-admin.service`: peer-credential Unix socket and privileged job queue.
- `getbible-alert@.service`: service-failure notifications independent of the
  collector, including when the collector itself cannot stay running.

Authentication state lives in `/var/lib/getbible/dashboard`; job state in
`/var/lib/getbible/admin`; telemetry in `/var/lib/getbible/telemetry`. These paths
are already under the persistent Compose state mount. Numeric service identities
are recorded in the existing identity registry before mounted data is accessed.

Automated tests cover broker argument validation, private-file import rejection,
credential redaction, one-time token disclosure, interrupted jobs, authentication
state, reporting sleep/wake and trusted proxy rendering. Chromium tests exercise
sign-in, charts, filters, management forms, themes and responsive layout.
Disposable Ubuntu and Docker acceptance tests exercise installed services,
nginx routing, external TLS forwarding and persistent state restoration; see
[DEPLOYMENT_DECISIONS.md](DEPLOYMENT_DECISIONS.md).
