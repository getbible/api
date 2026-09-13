# Logging and analytics

## One retained traffic history

`getbible-telemetry.service` continuously collects local traffic into
`/var/lib/getbible/telemetry/traffic.sqlite3`. Collection, basic system counters,
and capacity alerts continue while the dashboard sleeps. The dashboard and CLI
open read-only SQLite connections only when reports are requested.

nginx and runtime processes append records to short-lived transport spools.
They do not insert database rows or calculate statistics on the request path.
The collector commits batches and their input offsets together. The database
uses WAL mode with `synchronous=FULL`; a collector restart safely replays any
uncommitted input. An nginx record and its runtime semantic record share one
request row, joined by domain and request ID. Only the nginx record counts as
an origin request. Runtime rows still awaiting nginx are visible separately.

| Input | Information retained |
| --- | --- |
| `<log-root>/<domain>/access.log` | Client IP, URI/query, method, status, bytes, request/upstream duration, cache state, version, internal token ID, anonymous/valid/rejected authentication state, request ID, user agent, referer, transport details |
| `<log-root>/<domain>/app/<label>.log` | Runtime operation, translation, search text and criteria, scripture references, resolved/requested books, returned counts, worker PID, errors and generation information |
| `<log-root>/<domain>/error.log` | nginx diagnostic text, including malformed records as explicit diagnostic events |
| `<log-root>/dashboard/app/dashboard.log` | Administrative and authentication audit events with non-secret session references |
| getBible systemd journal units | Service/sync/timer diagnostics using a durable journal cursor |

nginx error logs are text; access and application spools are JSON lines.
Bearer headers are stripped at the proxy boundary. Credential-bearing fields,
cookies, passwords, OTPs, recognized sensitive URL parameters and Telegram bot
URLs are redacted again during collection. Internal token IDs identify accepted
API callers without exposing their bearer credentials. Producers must never
log dashboard credential bodies. Raw client addresses and request strings are
available only through authenticated dashboard/report interfaces.

Cloudflare responses served without contacting this origin do not appear in
local history. A separate Cloudflare analytics integration would be needed to
measure them.

## Stored request classification

The collector stores endpoint kind, version, operation, translation, book IDs
and book names when it ingests each request. Runtime-resolved fields take
precedence over path inference. Private response metadata carries resolved
translation and book identities into nginx access records, including origin
cache hits; nginx hides these headers from public responses. Query and search
text comes from their request paths/parameters and runtime records.

Static translation files, `books.json`, chapter/book files and their `.sha`
requests identify their translation. Numeric book IDs are resolved using the
local translation's `<version>/<translation>/books.json`, including additional books.
The collector caches this small metadata; reports use stored names and do not
read or download Bible data. Unknown names retain their book ID. Runtime
defaults are recorded as the translation actually selected (normally KJV).
Global discovery files, `robots.txt` and other non-scripture requests do not
become KJV requests merely because their translation is absent.

| Usage ranking | Included origin traffic |
| --- | --- |
| Popular translations | Successful static scripture/translation metadata and runtime query/search operations |
| Frequent searches | Successful operations on search endpoints, including references entered as searches |
| Scripture references | Successful scripture operations on query endpoints |
| Books of the Bible | Successful scripture operations with resolved book identities |

Success means HTTP 2xx or 304. Errors, redirects, preflights and unrelated
requests remain in Traffic and endpoint totals, but do not inflate these usage
rankings. Each ranking carries its own scope into the matching Traffic view.
Referrers and user agents are stored separately, with independent rankings,
exact filters and substring searches. Their audience counts include errors so
operators can investigate attempted access. Missing referrers are not replaced
by user agents. Traffic also supports a free-text search across request fields.

## Start a fresh history

The corrected classification uses telemetry schema 2. An earlier schema must
be explicitly reset; it is never silently converted or discarded by an update.
Apply the reviewed manager/runtime changes, then run this once if the collector
reports an earlier schema:

```sh
getbible logs reset --discard-history
```

If the first update stopped because the earlier-schema collector could not
start, reset it and repeat `getbible update` to finish applying every endpoint.
Reset once more after that update to exclude observations made during the
transition. The reset clears failed-service restart limits before recovery.

The CLI **Logs > Start a fresh traffic history** menu and dashboard
**Manage > Logs > History** expose the same action. It stops telemetry and
dashboard services while resetting canonical requests, events and metrics,
then restores services which were active or enabled. Authentication, settings,
API data and producer log files are retained. Producer offsets and the journal
cursor are retained, and a collection cutoff prevents earlier buffered records
from repopulating the new history. The reset itself is recorded as a retention
event. A reset is irreversible for the canonical history; it does not promise
that already-pruned producer files can reconstruct it.

## Retention and durability

| Setting | Default | Purpose |
| --- | ---: | --- |
| `GETBIBLE_TELEMETRY_MAX_GIB` | 10 | Canonical history storage budget |
| `GETBIBLE_TELEMETRY_RETENTION_DAYS` | 180 | Maximum history age, also subject to the byte budget |
| `GETBIBLE_TELEMETRY_BATCH_SIZE` | 1000 | Maximum records per input-file transaction |
| `GETBIBLE_TELEMETRY_FLUSH_SECONDS` | 1 | Collection polling interval; backlog drains immediately |
| `GETBIBLE_TELEMETRY_METRICS_SECONDS` | 5 | Container metric sampling interval |
| `GETBIBLE_TELEMETRY_SPOOL_MAX_GIB` | 1 | Spool pressure alert threshold |
| `GETBIBLE_TELEMETRY_SPOOL_ROTATE_MIB` | 16 | Rotate an active transport file at this size |

The manager supplies effective values through `/run/getbible/telemetry.env`.
The collector reloads this file every 30 seconds, validates all accepted values,
and keeps the previous configuration if validation fails. Shell expressions
are never evaluated.

Pruning always removes the oldest stored records first, across requests,
diagnostics and system metrics. It never deletes API corpus publications or
rollback releases. The database records deleted time ranges and row counts;
the dashboard shows the earliest available request and retention gaps. A
180-day setting is a target, not a guarantee that six months of detailed
traffic fits in 10 GiB. Recent details take precedence over older details.

The collector performs incremental vacuum and WAL checkpoints. These limits
are application budgets, not filesystem quotas: concurrent readers, active
input files and a large batch can temporarily exceed them. A host filesystem
quota is required for a hard physical limit. Active-reader query deadlines
prevent unbounded report snapshots from pinning the WAL.

The collector rotates transport files and signals nginx to reopen them.
Committed `.spool` files are deleted only after their size stabilizes and no
producer still has them open. Unread files are never silently pruned; backlog,
oversized input, truncation and disk failures are reported explicitly. Existing
compressed archives can be imported through the same cursor reader; they are
retained for operator review rather than removed automatically. New traffic
has only one permanent history store. The compatibility logrotate timer now
asks the collector to rotate spools; independent logrotate rules are intentionally
empty so they cannot delete unread input.

Buffered logging is not a zero-loss guarantee under host power loss or full
disk failure. nginx flushes at most once per second or when its buffer fills;
the collector then commits a batch. Producer data still in userspace or kernel
writeback can be lost on a host failure. A full/unwritable spool can lose new
records; application warnings and collector failures also reach journald as
an emergency diagnostic channel. The system does not claim exact counts across
an unreported disk failure or journal vacuum gap.

## Reports and live data

```sh
getbible.sh analytics --window 24h --domain bible.example.com --json
getbible-telemetry summary --db /var/lib/getbible/telemetry/traffic.sqlite3 \
    --from 2026-06-01T00:00:00Z --to 2026-07-01T00:00:00Z
getbible-telemetry requests --endpoint bible.example.com --limit 100
getbible-telemetry events --from 0 --limit 100
getbible-telemetry storage
```

Time ranges are half open: the start is included and the end excluded.
Request pagination follows ingestion ID so delayed runtime/rotation records
can be discovered; timestamps still determine all range filters and pruning.
Reports calculate over every retained matching row, with parameterized filters
and bounded result pages. They do not sample the first 200,000 requests or
re-read compressed archives when opened. Dashboard latency percentiles are
explicit histogram upper-bound estimates; histogram counts include every
matching request. The CLI analytics report preserves its exact percentile
query and its caller definition (IPv6 grouped by /64). It excludes preflights
from `total_calls`; dashboard origin calls include them and report preflights
separately. CLI reports do not print raw IP addresses.

Read-only connections have a total query deadline. An expensive range returns
a timeout rather than silently incomplete results; narrow the time range or
filter by endpoint. Live history normally trails an origin request by the
nginx flush and collection interval. Browser charts stop querying when the
dashboard sleeps; collection continues independently.

## System health

CPU usage is shown in CPU units and as a fraction of the visible cgroup quota.
Memory, swap, throttling, pressure, PIDs and filesystem free space come from
Linux counters. Temperatures appear only when sensors are exposed to the
container. Per-translation resident sizes are estimates supplied by the
runtime control API, separate from actual process/container memory counters.

`GETBIBLE_ALERT_CPU_PERCENT`, `MEMORY_PERCENT`, `DISK_PERCENT` and
`MEMORY_PRESSURE_PERCENT` select sustained capacity thresholds. The full
variable names share the `GETBIBLE_ALERT_` prefix. Hold and notification cooldown
are controlled by `GETBIBLE_ALERT_HOLD_SECONDS` and
`GETBIBLE_ALERT_COOLDOWN_SECONDS`; defaults are 60 and 900 seconds. Recovery
messages are emitted once when a previously alerted condition clears.

Managed failed services are checked without blocking traffic collection.
Sync freshness compares successful `LAST_CHECK` with the actual systemd timer
trigger plus `GETBIBLE_ALERT_SYNC_GRACE_SECONDS` (3600 seconds). An unchanged
repository with a successful monthly check is healthy even if its last
publication is old. Diagnostics and health alert state persist in the same
telemetry database.
