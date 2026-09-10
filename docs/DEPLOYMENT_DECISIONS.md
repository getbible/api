# Deployment objectives and decisions

This records the reasons for the native and Docker deployment design. Use it
with [DOCKER.md](DOCKER.md), [OPNSENSE_HAPROXY.md](OPNSENSE_HAPROXY.md), and
[CLOUDFLARE.md](CLOUDFLARE.md) when changing implementation or operator flows.

## 1. Availability and legitimate consumption

getBible should be consumed heavily. Fast access and high availability are
product objectives. Origin rate limits protect finite server capacity; they
are not a contractual count of every public request. An anonymous caller on
an open or metered domain may receive many responses from Cloudflare without
reaching an origin limit or appearing in origin analytics. This is intended:
the CDN should absorb repeated public reads.

Bearer-token holders retain unlimited access under the existing access model.
Token-only data stays private and must pass authentication even if an earlier
public version of that URL was cached. Authentication failures, rate-limit
responses and private data must never become shared public cache entries.
Documentation, discovery, preflights and health remain public as specified by
the endpoint contracts.

Trusted source repositories and sanctioned operators remain trusted. Builders
own corpus correctness; this manager publishes their committed files
faithfully and atomically. Docker support does not introduce downstream corpus
validation, checksums sweeps, repository approval gates, extra user quotas or
mandatory production corpus load tests.

## 2. One system container, same management model

Keep native installation and add Docker as an execution mode in the same
codebase. Execution mode and TLS ownership are separate settings: a native
host can also use external TLS. Test fixture path redirection (`GB_PREFIX`)
is not Docker detection.

The Docker deployment is one Linux system container with systemd as PID 1.
It contains nginx, all configured domains, static synchronization, query and
search services, timers, journals, log rotation and the existing manager.
Systemd continues to provide service users, sandboxes, resource controls,
socket activation, readiness, scheduling and generation retirement.

Each static domain keeps its own sync identity. Runtime kinds retain the
existing one-domain-per-kind layout: one query domain and one search domain
can each contain supported version endpoints. This change does not introduce
arbitrary duplicate query/search installations under conflicting paths.

`getbible` is an executable command in the image, linked to the existing
manager. It is not a shell alias and works in both interactive terminals and
noninteractive `docker compose exec` commands. Operators need only the
deployment files on the host; no manager checkout or host wrapper is needed.

## 3. Domain routing and TLS responsibilities

Cloudflare proxies public HTTPS traffic to OPNsense HAProxy over HTTPS.
HAProxy owns the origin certificates and their renewal, then sends HTTP to
one published Docker port on the LAN. Container nginx dispatches by the
preserved HTTP `Host`, so domains do not need separate published ports.

Cloudflare uses Full (strict): its TLS peer is HAProxy. The plaintext LAN leg
does not justify Flexible SSL mode. External TLS mode serves complete nginx
virtual hosts over HTTP and retains public HTTPS URLs. Native managed TLS
continues to use Certbot.

HAProxy preserves `Host` and `Authorization`, verifies the source before
accepting Cloudflare's client-address header, and sends one normalized client
address and the public scheme to nginx. nginx trusts only the configured
proxy peers. nginx owns bearer validation and supplies the internal token ID;
raw bearer credentials are stripped before the runtime application.

No launch or restart silently takes over public DNS. Staging and explicit
go-live remain meaningful with either TLS owner. External go-live checks the
local HTTP origin separately from the public HTTPS route and its externally
managed certificate.

## 4. Cloudflare Free is the baseline

Cloudflare management remains optional and off by default for native installs.
The supplied external-proxy Docker profile uses proxied Cloudflare and public
cache respect mode by default. API clients receive JSON data and problem
documents without an intentional browser challenge flow.

Public GET/HEAD responses are eligible for edge caching with their configured
freshness policy, including parameterized requests when the complete query
string is preserved in the cache key. Authorization-bearing requests bypass
the edge cache so the origin's token behavior still executes. Token-only
transitions install bypass rules and purge previously public hostname content.

Use features available to Free zones unless the operator explicitly selects
paid capabilities and the actual zone entitlement supports them. Payment is
not implied by the presence of an API token. Rule capacity is shared with
other subdomains in a zone; update only getBible-owned records and rules.
Document any zone-wide prerequisite instead of silently changing unrelated
sites. Cloudflare-specific plans, limits and known error/challenge limitations
belong in [CLOUDFLARE.md](CLOUDFLARE.md).

## 5. Prepared images and explicit releases

GitHub Actions builds the image and publishes it privately to GitHub Container
Registry. The server Compose file pulls it and does not build it. The image
contains OS dependencies, management code, reviewed Python distributions and
the pinned runtime dependency artifacts needed to deploy the offered runtime
implementations without runtime Internet package installation or compilation.
The operator still selects domains, endpoints, data repositories, access modes
and credentials; Bible data is obtained through the existing synchronization
workflow rather than embedded as a production corpus in the image.

Publish stable numbered image tags and a moving `latest` tag. Default the
production example to a numbered release. The first release is `1.0.0`;
subsequent patch, minor and major numbers describe fixes, compatible features
and breaking changes. These are deployment-software versions, independent of
Bible API endpoint versions. A numbered tag must not be overwritten.

Docker manager and OS-package updates arrive in a new image. Native manager
updates continue to use Git. Applying new templates or redeploying endpoints
remains explicit; a container restart restores its saved local installation
without fetching upstream code, changing public DNS or requesting certificates.
Replacing a whole container causes a service restart. It is distinct from an
in-container runtime update with overlapping candidates, readiness, graceful
nginx reload and retained rollback generations.

## 6. Configuration and persistence

Environment settings take precedence over saved global settings; saved settings
take precedence over defaults. The manager must identify environment-controlled
settings and avoid claiming to persist an effective override. Credentials can
be supplied through supported mounted-file settings. Per-domain choices and
tokens remain in the existing registry.

All managed persistent state can live under one host directory. Subdirectory
mounts preserve the native paths used by services. This includes configuration,
data and release trees, runtime interpreters and releases, SSH identities,
custom pages, caches, logs, journals, generated units and backups. Immutable
image code lives outside mounts that could hide a replacement image.

A structured UID/GID registry and readable identity log preserve managed
accounts across container replacement. Restore accounts and groups before
services can read mounted files. Validate name/number conflicts first; do not
resolve them by indiscriminately changing ownership of the entire dataset.
Backups preserve numeric ownership, ACLs, symlinks and hard links.

## 7. Resource budgets and performance

Docker sets an aggregate memory limit. The manager budgets resources across
the active runtime endpoints under the effective cgroup limit, with room for
nginx, systemd, file cache, synchronization, request work and overlapping
deployment generations. Native deployments can opt into an explicit aggregate
application budget while retaining host memory for other services.

Workers, concurrency, warm translations and librarian cache entry limits are
capacity choices; a cache entry is not a fixed number of bytes. A memory cap
does not guarantee that every translation can remain warm or that any workload
will have the same throughput. The kernel can terminate processes at a hard
limit. When a candidate cannot fit, preserve the serving generation and report
the capacity problem. Use the librarian's public controls; extend that project
if more precise cache behavior is needed.

Docker adds no request-time compilation. The native and container paths retain
nginx and Unix-socket runtime dispatch. Performance conclusions must come from
equivalent-resource measurements; warm/cold caches, concurrency and memory
pressure matter more than an invented universal overhead percentage.

## 8. Acceptance and ownership

Repository tests cover rendering and behavior; the system container also needs
real rootful Linux/cgroup-v2 acceptance. Preserve service sandbox protections
and document the container authority necessary for systemd. A Dockerfile alone
does not establish that nested services boot or that resource controls work.

Deployment acceptance verifies two domains through the same backend port,
forwarded identity and public scheme, bearer handling, public cache hits,
private cache bypass, clean shutdown, container recreation with the same
numeric owners and keys, and runtime rollback. Use disposable test fixtures.
An integration guide does not mean a customer's firewall or Cloudflare account
has been changed or validated. Record the actual installed versions and test
results when the deployment is commissioned.
