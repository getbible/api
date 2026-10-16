# Runtime resources, resident caches and publication freshness

The container's `GETBIBLE_CPU_LIMIT` and `GETBIBLE_MEMORY_LIMIT` are aggregate
ceilings, not reserved CPU cores or eagerly allocated RAM. Choose these limits
from the capacity available to this deployment. Production throughput and corpus
residency need measurements against the deployed translations and actual requests.

`getbible resources show --json` explains the current allocation. It includes
all enabled runtime endpoints and reserves infrastructure memory plus space for
an overlapping replacement of the largest runtime domain. Each endpoint has a
finite systemd memory ceiling. Docker `CPU_QUOTA=auto` clears the former 200% or
400% child quota, allowing either runtime to use available CPU inside the
container's aggregate cap. Native auto retains the kind's manifest CPU quota.
An explicit `250%` means at most 2.5 CPU units; it does not bind physical cores.

## Configuration

Every global key below has a `GETBIBLE_` deployment environment form. Explicit
environment values are authoritative over saved endpoint overrides. Saved global
values are defaults; endpoint-specific settings can override those defaults.

Native installations use built-in defaults without an environment file. Persist
changes through the menu or `sudo ./getbible.sh settings set KEY VALUE`;
`settings environment` shows effective values and their sources. A variable
passed to one native command affects that invocation; use saved settings for
values that must survive reboot. Native defaults retain managed TLS and do not
enable Cloudflare or the dashboard automatically.

Docker startup captures supported nonempty `GETBIBLE_*` values for systemd and
reconciles existing runtime resource and cache settings. Recreating the container
with a changed override applies it; removing an override restores the saved/default
value. Restoration preserves endpoint code, identities and publication state.

| Global key | Default | Meaning |
| --- | --- | --- |
| `MEMORY_BUDGET` | `auto` | Container cap; explicit native aggregate budget also supported |
| `RESOURCE_RESERVE_PERCENT` | `25` | Infrastructure reserve, with a 256-MiB floor |
| `QUERY_MEMORY_MIN`, `SEARCH_MEMORY_MIN` | `192M`, `512M` | Minimum allocation before distributing spare memory |
| `QUERY_MEMORY_MAX`, `SEARCH_MEMORY_MAX` | `auto` | Optional per-endpoint allocation ceilings |
| `QUERY_CPU_QUOTA`, `SEARCH_CPU_QUOTA` | `auto` | Shared container CPU or explicit positive percentage |
| `QUERY_WORKERS_MIN`, `SEARCH_WORKERS_MIN` | `1` | Lowest automatic worker count |
| `QUERY_WORKERS_MAX`, `SEARCH_WORKERS_MAX` | `12` | Highest automatic worker count, further bounded by available CPU/memory |
| `QUERY_THREADS_MIN`, `SEARCH_THREADS_MIN` | `1` | Lowest thread count |
| `QUERY_THREADS_MAX`, `SEARCH_THREADS_MAX` | `16`, `8` | Highest thread count |
| `QUERY_WARM_TRANSLATIONS`, `SEARCH_WARM_TRANSLATIONS` | `kjv` | Separate comma-separated startup warm lists |
| `MEMORY_CACHE_TTL` | `2592000` | Resident-data freshness period in seconds; 30 days |
| `CACHE_TTL_JITTER` | `0` | Exact configured freshness by default; optional fraction below 1 |
| `CACHE_MEMORY_PERCENT` | `50` | Per-worker memory share for estimated retained corpus/chapter/translation objects |
| `SHARED_CORPUS_LIMIT`, `TRANSLATION_CACHE_LIMIT` | `256` | Additional retained-entry bounds; never promises of byte usage |
| `CHAPTER_CACHE_LIMIT`, `REFERENCE_CACHE_LIMIT` | `100000`, `50000` | Chapter and parsed-reference entry bounds |
| `ADAPTIVE_RESOURCES` | `true` | Sustained-demand worker/memory adjustment |
| `ADAPTIVE_ALLOW_IDLE_SHRINK` | `false` | Opt-in idle downscaling, which replaces warm worker caches |
| `ADAPTIVE_INTERVAL` | `15` | Sampling interval in seconds |
| `ADAPTIVE_COOLDOWN` | `300` | Minimum interval between deployment adjustments |
| `ADAPTIVE_HIGH_PERCENT`, `ADAPTIVE_LOW_PERCENT` | `80`, `20` | Demand thresholds |
| `ADAPTIVE_SUSTAINED_SAMPLES` | `4` | Consecutive samples needed before adjustment |

Endpoint `WORKERS=auto` enables automatic worker adjustment. A numeric worker
setting remains an operator-selected target, subject to finite resource caps.
Thread counts are bounded on generation creation; the controller changes worker
counts and allocation weights rather than resizing live Python thread pools.
Global `DEFAULT_QUERY_WORKERS` and `DEFAULT_SEARCH_WORKERS` seed new endpoints.

CPU scheduling shares spare CPU immediately. Worker counts and memory allocation
grow slowly after sustained demand; allocation weights adapt under actual memory
pressure. Idle downscaling is disabled by default to preserve warmed translations.
Changes use the ordinary candidate startup,
readiness, nginx validation/reload and graceful drain transaction. Failed
admission keeps the serving generation. Existing warm objects survive normal
requests and idle periods; replacing a worker or generation necessarily creates
a new process cache. Adaptation is not an assurance of uninterrupted residency
or improved throughput for every workload. Its decisions and last apply result
are recorded in `/var/lib/getbible/adaptive.json`.

## Cache lifecycle

The API passes these settings through Librarian's public API. Query startup
warming calls `warm_query` without a reference list, which loads all chapters'
lookup payloads subject to the query cache's entry and byte limits. Ordinary
query requests retain only the chapters they use. Search startup warming loads
the translation corpus and its case-insensitive, diacritic-folded search index
through `warm_translation`; chapter data used for a reference search is a
separate cache and does not measure search-corpus completeness.
Set either warm-list environment variable to `none` to disable that startup
warm list; an empty deployment variable means use saved/default settings.
Both happen before Gunicorn forks to permit copy-on-write sharing. Other
translations warm lazily when requested. Default request-count recycling is
disabled so a warm worker is not discarded after 10,000 calls.

A translation listed by several worker PIDs is resident in those workers; the
rows are not a count of warm-up attempts. Pre-fork objects may share physical
pages until modified. A manual warm checks each worker and skips an already
fresh, complete cache. Query completeness requires the public warm report's
loaded chapter count as well as current resident/fresh chapter counts. Merely
finding one cached chapter does not establish a complete warm-up. If a full
query warm cannot retain all chapters within its configured limits, it is
reported as partial and repeated warm requests do not repeat that same futile
load until freshness, source or limits change. Explicit reload remains available.
Search reload also prepares the same folded index as startup warming.

Memory TTL controls lazy freshness revalidation. Unchanged source SHA retains
its resident structures after revalidation. Changed source publication or
rollback invalidates affected runtime source generations independently of TTL.
Entry/estimated-byte bounds may evict data earlier under pressure; no finite
budget can guarantee that every translation stays resident. Byte estimates do
not include every interpreter, request, allocator, or shared-memory cost;
systemd/cgroup accounting is the actual overall measurement and hard ceiling.

HTTP TTL is separate: `DEFAULT_QUERY_CACHE_TTL` and
`DEFAULT_SEARCH_CACHE_TTL` seed endpoint `CACHE_TTL`. Runtime responses bound
freshness by the last successful source-check timestamp plus the configured HTTP
TTL. Unchanged successful checks renew this timestamp without discarding the
unchanged corpus. Manually provided repositories without this marker use the
ordinary configured response TTL.
Worker source checks inspect the atomic publication target at most once per
second without scanning Bible contents. The root controller observes source
changes and rotates the affected nginx response-cache namespace on its next
sample, using validated nginx reload with rollback. In-flight responses keep
their previous cache namespace; they cannot refill the current publication
cache. Responses crossing a publication change are marked no-store. It keeps doing source observation when adaptive sizing is disabled.

Already cached browser/CDN responses cannot be revoked by clearing origin RAM.
An early manual update may remain cached by consumers until its previously
issued HTTP expiry; monthly timers use calendar schedules while 2592000 seconds
is exactly 30 days. CDN cache hits are not visible in origin traffic statistics.

## Operator controls

### Review and realign hardware allocation

```sh
getbible resources realign
getbible resources realign --json
getbible resources realign --apply
```

The first two commands are read-only. They report effective CPU capacity,
physical and cgroup-limited RAM, available memory, filesystem byte/inode
headroom, configuration ownership, and selected versus proposed runtime
settings. They do not walk the Bible corpus or initialize an installation.
The existing capacity observations also distinguish collection/reclamation
problems from a request for more storage. Missing or stale observations are
reported explicitly.

Docker uses its finite effective cgroup memory allowance; the container cannot
raise the deployment's CPU or memory ceiling. An existing explicit application
budget is retained. Native installations with `MEMORY_BUDGET=auto` receive a
conservative proposal derived from both total and currently available memory,
leaving at least 25% of effective RAM (with a 256-MiB floor) for the host.
Existing runtime memory is not assumed reclaimable. The runtime allocator
then reserves infrastructure and deployment-overlap capacity within that
application budget. This is a starting allocation, not a throughput benchmark.
An operator can supply a deliberate shared-host budget with
`resources realign --memory-budget 4G` and review it before adding `--apply`.
After changing native hardware, `resources realign --memory-budget auto`
requests a new automatic recommendation instead of retaining a saved budget.

Every proposal has a plan identifier. `--expected-plan` accepts that identifier
to reject changed hardware, configuration or selected-generation settings.
When replaying a native automatic proposal later, pass its displayed proposed
`--memory-budget` as well as `--expected-plan`; otherwise changed available RAM
may produce a different proposal. The menu preserves both values internally.
Apply rechecks the plan under the manager lock, saves only an editable memory
budget when needed, and applies changed runtime domains through the existing
candidate-readiness, nginx validation/reload and drain transactions. Reductions
are applied before increases. As with `resources apply`, these transactions use
the installed manager's current runtime code and configuration for the selected
domains. A failed candidate retains its serving generation;
the command reports an incomplete application rather than claiming success.
Environment-owned settings must be changed at their deployment source.
Deliberately configured endpoint workers, cache policies and limits remain
subject to their existing precedence and hardware bounds.

The same review and apply controls are available under Settings > Deployment
settings > Hardware alignment and runtime memory budget. Alignment does not
increase telemetry allowances to conceal failed cleanup, remove data, change
storage admission policy, or change the host's container configuration.

```sh
getbible runtime query.example.org cache v2 info
getbible runtime query.example.org cache v2 warm kjv
getbible runtime query.example.org cache v2 drop kjv
getbible runtime query.example.org cache v2 reload kjv
getbible runtime query.example.org cache v2 refresh-source
getbible runtime query.example.org v2 set MEMORY_CACHE_TTL 604800
getbible runtime search.example.org v2 set WORKERS auto
getbible resources apply
```

The domain menu's Translation memory screen and dashboard use the same
allowlisted control helper. It fans out to every serving worker, reports each
PID and its measured RSS/private memory, and includes Librarian's per-translation
estimated cache usage. RSS includes shared pages and must not be summed as if
it were unique physical memory. Partial worker failures are reported explicitly.
The dashboard groups resident data by translation first; selecting one opens
the per-worker layer. Query chapters, search verses/index and snapshots have
separate columns. Warm-list configuration describes startup intent, while the
resident table and readiness state describe current observed memory.

Control listeners are private mode-0600 Unix sockets below the endpoint cache
directory, started after fork. Only root and the runtime service UID may use
them. Public query/search HTTP routes never expose these controls.

## Managed storage admission

`GETBIBLE_STORAGE_MAX_GIB=0` disables application storage admission. With a
positive cap, an independent root timer records managed allocated disk blocks
without reading file contents, deduplicating hard-linked releases. It samples
in bounded slices, 30 seconds after the previous invocation finishes,
independently of resource applications. Each slice has a 75-second systemd
deadline and normally yields after 20 seconds. A disk-backed directory queue,
checkpointed totals and hard-link index preserve completed work across timer
runs and process interruption without retaining the corpus's inode identities
in Python memory. Incomplete scans never replace the last complete snapshot.
It exits without scanning when the storage cap is disabled. Startup begins
the first slice; budgeted publication waits until a complete snapshot exists.

`STORAGE_SCAN_MAX_SECONDS` (default `900`, supported range `120`–`86400`)
limits the wall-clock horizon of a whole scan, including timer waits. Its
deployment override is `GETBIBLE_STORAGE_SCAN_MAX_SECONDS`. Exceeding the
horizon or encountering an unreadable directory records a failure and retains
the last complete accounting. The next invocation starts a new scan. Progress
and the last error are recorded in `progress.json`; scan work is private under
the storage state's `.scan` directory. No partial count authorizes publication.

A complete snapshot records its start, completion and duration. Freshness is
measured from its start and is bounded by twice the configured scan horizon
plus 40 seconds for timer/scheduling margin. This allows consecutive bounded
scans to complete without the old fixed 120-second freshness window expiring
mid-scan. Legacy snapshots retain the 120-second window. Increasing the scan
horizon therefore also increases the tolerated accounting age; do so only
when the observed corpus traversal needs it. This admission estimate is not
a strict physical disk quota.
Trusted sync services reserve conservative projected export space under one
shared lock before export, and recheck before publication. Stale accounting or
insufficient budget refuses publication and preserves current and rollback
releases. Failed exports release their reservation. Successful publications
retain a committed charge until a complete snapshot whose scan started after
publication covers the added storage. Sequential publications therefore cannot
reuse unaccounted headroom between scans. Uncommitted crashed leases expire
after 24 hours; committed charges do not expire merely with time.
Snapshot and reservations live in
`/var/lib/getbible/storage`.

This is an application admission guard, not a filesystem quota. Git fetches,
telemetry and other writers can consume space between samples; snapshots plus
outstanding reservations may conservatively count some storage twice. A strict
physical bound requires a host-supported filesystem quota. Never remove the
live corpus to reclaim room. Telemetry has its own oldest-first retention cap;
the dashboard reports both budgets and measured usage.

Service failure alerts share durable incident records under
`/var/lib/getbible/telemetry/service-alerts` between systemd and the collector.
The first failure reports the unit's result and exit status;
continuing failures send bounded reminders instead of one message per retry.
A retry in `activating` state or `reset-failed` is not recovery. Storage recovery
also requires a newer complete, fresh accounting snapshot. An ingested rotated
telemetry spool is not necessarily closed: `getbible capacity --json` reports
the reclamation reason before any safe removal. Keep unread files and files
with writable descriptors intact.

## Verification

The CI suite checks allocation and update overlap, environment precedence,
CPU sharing, memory maxima, public cache operations, publication boundaries,
adaptive hysteresis, storage reservations and hard-link accounting. Disposable
Ubuntu acceptance tests exercise real Unix sockets, systemd services, nginx,
candidate readiness, graceful drain and rollback. Docker acceptance checks
cgroup limits, offline deployment and restoration after container recreation.
