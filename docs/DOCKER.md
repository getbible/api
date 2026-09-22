# Docker deployment

The production deployment pulls a prepared image. The Docker host
does not clone the manager repository or build a Dockerfile. A single
container runs systemd, nginx, the existing menu, static synchronization,
query/search runtimes and their maintenance services. OPNsense HAProxy remains
external and terminates HTTPS. See [deployment decisions](DEPLOYMENT_DECISIONS.md)
for the design objectives and [OPNSENSE_HAPROXY.md](OPNSENSE_HAPROXY.md) for
the complete OPNsense setup order, backend-pool field values, automatic
Cloudflare client-IP recognition, direct HTTPS access and certificate routing.

## 1. Host requirements

Use a Linux host with rootful Docker Engine, the Docker Compose plugin and
cgroup v2. The image is based on Ubuntu 24.04; native installation supports
Ubuntu 24.04/26.04 separately. Use the image variant for the host's CPU
architecture. Production should run natively on AMD64 or ARM64, not through
CPU emulation. Rootless Docker, Docker Desktop and cgroup-v1 hosts are not the
supported system-container profile.

Inspect the host before deployment:

```sh
uname -m
docker version
docker compose version
docker info --format 'cgroup={{.CgroupVersion}} driver={{.CgroupDriver}} security={{json .SecurityOptions}}'
```

The supplied Compose file intentionally retains systemd. It uses a private
cgroup namespace, `SYS_ADMIN` for nested service mount namespaces and
`apparmor:unconfined` because Docker's default AppArmor profile prevents those
mounts. Docker's default seccomp filter remains in use. It does not request
`privileged`, bind the host cgroup hierarchy, mount the Docker socket or share
host account databases. This is broader container authority than an ordinary
single-process web container; the image is managed as trusted system software.
Individual endpoint units still drop capabilities and enforce their existing
users, read-only paths and sandbox settings.

The entrypoint checks for cgroup v2 and a private cgroup namespace before
making its own cgroup tree writable. A host that cannot support the required
isolation reports an initialization error; do not remove service protections
to conceal that error. Commissioning requires a real systemd/container boot
and service test on the actual host, not only a successful image build.

## 2. Obtain deployment files and authenticate

Download [compose.yaml](../compose.yaml) and [.env.example](../.env.example)
from the repository on your workstation, then copy them
into the deployment directory on the Docker host, such as
`/srv/getbible-deployment`. Name the settings file `.env`. Use the files from
the same release as the image; the server needs no Git checkout or build tools.

The image is `ghcr.io/getbible/api`. For a private package, authenticate Docker
once with a dedicated account's read-only package token, using the same host
user that runs Compose. Docker retains that login for subsequent pulls; selecting
`GETBIBLE_IMAGE_TAG=latest` does not require authenticating again for each image.
See [private registry access](REGISTRY_ACCESS.md) for account/package access,
token permissions, credential storage and the complete login/update commands.
Registry credentials stay on the host and are not application environment
variables or endpoint SSH deploy keys.

## 3. Set the installation settings

Set the actual LAN/proxy and WAN addresses in `.env` before startup:

```dotenv
GETBIBLE_IMAGE_TAG=2.0.0
GETBIBLE_DATA_ROOT=/srv/getbible-data
GETBIBLE_BIND_ADDRESS=10.0.0.20
GETBIBLE_HTTP_PORT=8080
GETBIBLE_MEMORY_LIMIT=4g
GETBIBLE_CPU_LIMIT=2.0
GETBIBLE_TLS_MODE=external
GETBIBLE_TRUSTED_PROXY_CIDRS=10.0.0.1/32
GETBIBLE_PUBLIC_SCHEME=https
GETBIBLE_ORIGIN_HTTP_PORT=80
GETBIBLE_DEFAULT_DEPLOY_MODE=staged
GETBIBLE_CLOUDFLARE_ENABLED=true
GETBIBLE_DEFAULT_CLOUDFLARE_MODE=proxied
GETBIBLE_DEFAULT_CLOUDFLARE_CACHE=respect
GETBIBLE_DEFAULT_CLOUDFLARE_FEATURES=free
GETBIBLE_SERVER_PUBLIC_IPV4=203.0.113.20
GETBIBLE_SERVER_PUBLIC_IPV6=none
```

The addresses above are examples. Public addresses must identify the firewall
origin reachable by Cloudflare, not a Docker address or an unrelated local
IPv6 interface. Set unused IPv6 to `none`; an empty setting preserves existing
AAAA records, so it does not disable IPv6. The example publishes
one HTTP port for all domains; open that LAN route from HAProxy. The template
defaults to `0.0.0.0`, so select the intended LAN address for production.

Cloudflare can still advertise IPv6 edge addresses for a proxied hostname
whose origin uses IPv4 only. This does not require an origin AAAA record or
an IPv6 listener on HAProxy. Follow the [IPv4-only origin explanation](OPNSENSE_HAPROXY.md#ipv4-only-origins-and-ipv6-visitors)
and [backend-pool form settings](OPNSENSE_HAPROXY.md#5-create-the-backend-pool).

Configure the Cloudflare API token through the menu or a supported environment
setting, with permissions described in [CLOUDFLARE.md](CLOUDFLARE.md). Starting
an empty container does not create domains or take over DNS. Staged domains
can be prepared before the explicit public go-live.

### Environment precedence

Nonempty supported `GETBIBLE_*` application settings override saved global
configuration. Saved configuration overrides built-in defaults. Empty optional
values leave the menu/saved setting in control. The manager reports when a
setting is environment-controlled and refuses a conflicting saved edit. Change
the deployment environment and recreate the container to change that override.

Compose's `.env` is used for interpolation; it is not automatically copied
wholesale into the container. [compose.yaml](../compose.yaml) explicitly passes
the supported application variables. Container initialization also makes the
effective settings available to the installed systemd jobs. Per-domain access,
tokens, repository identities and runtime choices remain in the existing
registry and are managed with the existing menu/CLI.

Saved per-domain choices remain authoritative unless a supported environment
override applies. A new image release refreshes enabled endpoints automatically.
For changes made while staying on the same image, use `getbible update` or the
runtime/resource commands to apply the effective configuration.
The full settings inventory follows.

### Container settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `GETBIBLE_IMAGE_REPOSITORY` | `ghcr.io/getbible/api` | Registry/repository without a tag |
| `GETBIBLE_IMAGE_TAG` | `2.0.0` | Numbered stable release; `latest` is optional |
| `GETBIBLE_DATA_ROOT` | `/srv/getbible-data` | Absolute host parent for persistent subdirectory mounts |
| `GETBIBLE_HOSTNAME` | `getbible` | Container hostname |
| `TZ` | `UTC` | Installed IANA time zone |
| `GETBIBLE_BIND_ADDRESS` | `0.0.0.0` | Host interface for published HTTP; choose the LAN address |
| `GETBIBLE_HTTP_PORT` | `8080` | Published host TCP port |
| `GETBIBLE_MEMORY_LIMIT` | `4g` | Container hard RAM limit; memory+swap is set equal, disabling swap |
| `GETBIBLE_CPU_LIMIT` | `2.0` | Docker CPU quota, in CPU units |
| `GETBIBLE_PIDS_LIMIT` | `4096` | Aggregate process/thread ceiling |
| `GETBIBLE_SHM_SIZE` | `64m` | `/dev/shm` capacity |
| `GETBIBLE_STOP_GRACE_PERIOD` | `120s` | Time for systemd to stop services after `SIGRTMIN+3` |

The Compose service fixes `GB_EXECUTION_MODE=docker` and `container=docker`.
Do not select native mode inside this image. Docker owns port publication,
container resource ceilings and process lifecycle; changing these settings
requires container recreation.

### Application defaults and proxy settings

An empty optional variable in `.env` uses the saved setting or the default
shown below. `DEFAULT_*` settings seed newly deployed endpoints/domains;
existing domain-specific choices stay in their registry.

| Variable | Fresh installation default | Accepted value/purpose |
| --- | --- | --- |
| `GETBIBLE_TLS_MODE` | `external` in Compose | `external` or `managed`; external is the OPNsense profile |
| `GETBIBLE_TRUSTED_PROXY_CIDRS` | empty; set for external proxy use | Comma-separated actual HAProxy source IPs/CIDRs |
| `GETBIBLE_PUBLIC_SCHEME` | `https` | Public URL scheme; currently accepts `https` |
| `GETBIBLE_ORIGIN_HTTP_PORT` | `80` | nginx's serving HTTP port; Compose maps the same target |
| `GETBIBLE_DEFAULT_DEPLOY_MODE` | `staged` | `staged` or `live` |
| `GETBIBLE_DEFAULT_ACCESS_MODE` | `metered` | `open`, `metered`, `token` |
| `GETBIBLE_DEFAULT_RATE_PER_SECOND` | `50` | Public origin requests per second |
| `GETBIBLE_DEFAULT_RATE_BURST` | `250` | Public origin burst allowance |
| `GETBIBLE_DEFAULT_QUOTA_HOUR` | `10000` | Existing public hourly token-bucket setting |
| `GETBIBLE_DEFAULT_QUOTA_DAY` | `100000` | Existing public daily token-bucket setting |
| `GETBIBLE_DEFAULT_CONN_LIMIT` | `100` | Concurrent public origin connections |
| `GETBIBLE_DEFAULT_CACHE_TTL` | `3600` | Public static data freshness, seconds |
| `GETBIBLE_DEFAULT_SHA_CACHE_TTL` | `300` | Static change-token freshness, seconds |
| `GETBIBLE_DEFAULT_QUERY_CACHE_TTL` | `300` | Query GET/HEAD freshness, seconds |
| `GETBIBLE_DEFAULT_SEARCH_CACHE_TTL` | `60` | Search GET/HEAD freshness, seconds |
| `GETBIBLE_DEFAULT_QUERY_WORKERS` | `4` | Desired query worker count before resource allocation |
| `GETBIBLE_DEFAULT_QUERY_THREADS` | `4` | Desired query threads per worker |
| `GETBIBLE_DEFAULT_SEARCH_WORKERS` | `2` | Desired search worker count before resource allocation |
| `GETBIBLE_DEFAULT_SEARCH_THREADS` | `4` | Desired search threads per worker |
| `GETBIBLE_DEFAULT_SYNC_SCHEDULE` | `weekly` | `daily`, `weekly`, `monthly` |
| `GETBIBLE_DEFAULT_EXTENSIONS` | `json,sha,txt` | Allowed static file extensions, comma-separated |
| `GETBIBLE_LOG_ROTATE_SIZE` | `1G` | Per-log rotation threshold |
| `GETBIBLE_LOG_ROTATE_KEEP` | `30` | Retained archives |
| `GETBIBLE_HSTS_INCLUDE_SUBDOMAINS` | `false` | `true` only when all affected subdomains use HTTPS |
| `GETBIBLE_MEMORY_BUDGET` | `auto` | Automatic Docker cgroup budget or positive bytes/size such as `3G` for a lower application budget |

The supplied Compose profile publishes HTTP only. Selecting local managed TLS
also requires publishing its HTTPS listener and configuring direct certificate
validation; do not change only `TLS_MODE` while retaining an external-TLS
network layout. Native managed-TLS instructions are in [INSTALL.md](INSTALL.md).

### Cloudflare and notifications

| Variable | Fresh installation default | Meaning |
| --- | --- | --- |
| `GETBIBLE_CLOUDFLARE_ENABLED` | `true` in Compose | Enable configured Cloudflare integration |
| `GETBIBLE_DEFAULT_CLOUDFLARE_MODE` | `proxied` | Default domain mode: `off`, `dns`, `proxied` |
| `GETBIBLE_DEFAULT_CLOUDFLARE_CACHE` | `respect` | Public origin cache policy: `respect` or `bypass` |
| `GETBIBLE_DEFAULT_CLOUDFLARE_FEATURES` | `free` | `free` or `paid`; paid also needs verified entitlement |
| `GETBIBLE_CLOUDFLARE_API_TOKEN` | empty | Token used for owned DNS/rule/cache operations |
| `GETBIBLE_CLOUDFLARE_API_TOKEN_FILE` | empty | Container path to a file holding that token |
| `GETBIBLE_SERVER_PUBLIC_IPV4` | empty | Explicit firewall WAN IPv4 |
| `GETBIBLE_SERVER_PUBLIC_IPV6` | empty | Explicit firewall WAN IPv6, or `none` |
| `GETBIBLE_TELEGRAM_ENABLED` | `false` | Enable configured change notifications |
| `GETBIBLE_TELEGRAM_BOT_TOKEN` | empty | Telegram bot credential |
| `GETBIBLE_TELEGRAM_BOT_TOKEN_FILE` | empty | Container path to a file holding that token |
| `GETBIBLE_TELEGRAM_CHAT_ID` | empty | Destination chat for configured notifications |
| `GETBIBLE_TELEGRAM_HOSTNAME` | `getbible` | Stable installation label in notifications |
| `GETBIBLE_CERTBOT_EMAIL` | empty | Contact email; used with local managed TLS only |
| `GETBIBLE_CERT_METHOD` | `auto` | Local managed TLS: `auto`, `http`, `dns-cloudflare` |

For example, store the Cloudflare token as a root-only file at
`/srv/getbible-data/config/cloudflare-token`, then set:

```dotenv
GETBIBLE_CLOUDFLARE_API_TOKEN_FILE=/etc/getbible/cloudflare-token
```

Leave the direct token variable empty when using the file. The token file is
inside the existing configuration mount. Alternatively add a Compose secret
and point the `_FILE` variable at its container path. Do not commit credentials
to the repository. Protect `.env`, the token files and their backups from
other host users.

## 4. Start and operate

From the deployment directory:

```sh
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
docker compose exec --user root getbible getbible doctor
docker compose exec --user root getbible getbible settings environment
docker exec -it --user root <container-name> getbible
```

From the Docker host, use the container's name to open the management menu:

```sh
docker exec -it --user root <container-name> getbible
```

To open a command shell instead:

```sh
docker exec -it --user root <container-name> /bin/bash
```

Replace `<container-name>` with the name shown by `docker ps`. Inside this root
shell, run commands directly, such as `getbible dashboard update`,
`getbible dashboard status`, or `getbible update`; do not add `sudo`.
The menu is not a command shell: close it and use the `/bin/bash` command above
to enter shell commands.
Run `exit` to return to the Docker host before using `docker compose pull`,
`docker compose up -d`, or other Docker image commands.

`getbible` is a symlink to the manager entry point on the image's executable
path, not a shell alias. It passes all arguments unchanged. No endpoint data
or public domains are preconfigured. Use the existing menu to deploy static
domains, register their per-endpoint SSH public keys, synchronize scripture,
then deploy query and search against that local data. The image bundles all
offered runtime dependencies; those steps do not download Python, contact
PyPI or compile packages.

One query domain and one search domain retain their existing per-kind layout;
each can contain multiple supported version endpoints. Multiple static domains
also share nginx's one published HTTP port. Container paths shown by the menu
are the paths to use for local runtime data, such as `/srv/getbible/...`, not
the host's `/srv/getbible-data/...` paths.

Common commands:

```sh
# Interactive management menu and full command reference
docker exec -it --user root <container-name> getbible
docker compose exec --user root getbible getbible --help

# Domains, endpoint data access and explicit synchronization
docker compose exec --user root getbible getbible list
docker compose exec --user root getbible getbible status
docker compose exec --user root getbible getbible deploy-key api.example.org v2
docker compose exec --user root getbible getbible repo-access api.example.org v2
docker compose exec --user root getbible getbible sync api.example.org v2

# Explicit public launch and route verification
docker compose exec --user root getbible getbible go-live api.example.org
docker compose exec --user root getbible getbible verify api.example.org

# Logs, allocated resources and an administrative shell
docker compose exec --user root getbible getbible logs api.example.org access --lines 50
docker compose exec --user root getbible getbible resources show
docker compose logs --tail 100 getbible
docker exec -it --user root <container-name> /bin/bash

# Noninteractive use, suitable for a host-side automation job
docker compose exec -T --user root getbible getbible list
```

The manager, sync jobs and runtime services use their established users and
permissions inside the container. Operators enter as root to administer them;
the application workers do not run as root. systemd timers remain inside the
container. Do not duplicate synchronization or log rotation with extra host
cron jobs.

Health checks inspect initialization, nginx and selected active runtime
generations. Empty installations can be healthy before endpoints exist. Docker
marks a failing health check unhealthy; the restart policy restarts exited
containers and does not itself restart an unhealthy but still-running one.
Inspect logs and `getbible status` to identify the failing service.

## 5. Memory and CPU allocation

`GETBIBLE_MEMORY_LIMIT` is the aggregate Docker ceiling. Swap is disabled by
setting the memory-plus-swap ceiling to the same value. The application uses
the effective cgroup limit, not the host's total RAM, and may be given a lower
`GETBIBLE_MEMORY_BUDGET`. CPU worker targets also account for visible CPU quota.
The Docker daemon itself is outside the container's memory limit.

Allocation reserves the greater of 256 MiB or 25 percent for system services,
file cache, synchronization and other work. Enabled runtime endpoints receive
minimum shares (query 192 MiB, search 512 MiB), with spare capacity weighted
toward search. It also reserves the largest domain's candidate generations
because the versions of a domain are prepared together during an update.
These are allocation parameters, not measured promises about a complete Bible
corpus. Four GiB is the example budget for a basic query/search installation,
not a guarantee that every translation stays warm.

Effective workers, threads, search concurrency, warm sets and public librarian
cache-entry limits adapt to allocation. Desired configuration is retained;
translation access and response semantics are not removed to fit memory.
Cache entry counts are not byte guarantees. Runtime readiness is still the
test that a candidate can serve its configured data. The kernel may kill a
process that reaches a hard ceiling.

```sh
docker compose exec --user root getbible getbible resources show
docker compose exec -T --user root getbible getbible resources show --json
docker compose exec --user root getbible getbible resources apply
```

The report distinguishes calculated targets from running generations.
Configuration changes recalculate targets; `resources apply` activates them
through the normal candidate/readiness/reload workflow. Deploying an additional
runtime first gives other affected domains healthy replacements with smaller
allocations, then drains their old generations before consuming the released
capacity. Removing an endpoint reallocates the remaining domains. Existing
workers do not change in place. Before activation, preflight accounts for active
and still-retiring generations; insufficient update headroom leaves the
serving generation in place and reports the capacity problem. Boot restoration
applies its calculated runtime settings before starting saved services.

Native `MEMORY_BUDGET=auto` preserves the established manifest limits; a
native operator can select an explicit aggregate budget. Do not lower a
container limit below the running installation's requirements without checking
the new allocation and planning the restart.

Containers share the Linux kernel and add no request-time compilation. Measure
native and Docker responses from the firewall under equal resource limits,
data, concurrency and warm/cold cache conditions if a performance comparison
is needed. No universal overhead percentage is assumed.

## 6. Persistent data and container replacement

All managed persistent data uses one host parent, normally
`/srv/getbible-data`. Do not run two containers against the same installation.

| Host subdirectory | Container path | Contents |
| --- | --- | --- |
| `config` | `/etc/getbible` | Global/domain settings, bearer tokens, notification/Cloudflare credentials |
| `state` | `/var/lib/getbible` | Ledger, sync homes and endpoint SSH keys, identities, machine ID |
| `backups` | `/var/backups/getbible` | Manager configuration backups |
| `data` | `/srv/getbible` | Published static trees and all release targets |
| `runtime` | `/opt/getbible` | Managed Python, application releases, active/previous generations |
| `pages` | `/var/www/getbible` | Generated and operator-maintained pages/icons/OpenAPI |
| `cache` | `/var/cache/getbible` | Runtime/librarian/nginx cache files |
| `nginx` | `/etc/nginx` | nginx configuration, snippets and token maps |
| `nginx-logs` | `/var/log/nginx` | nginx's global diagnostics outside per-domain logs |
| `nginx-cache` | `/var/cache/nginx/getbible` | nginx's shared runtime proxy cache |
| `systemd` | `/etc/systemd/system` | Managed units, drop-ins and enable links |
| `certificates` | `/etc/letsencrypt` | Local managed-TLS certificates when that mode is used |
| `logs` | `/var/log/getbible` | Access/application/error logs and rotated archives |
| `journal` | `/var/log/journal` | Persistent systemd journal |

`/run` and temporary sockets/PIDs are ephemeral. The image's management code
under `/usr/share/getbible/api` is not hidden by the `/opt/getbible` mount.
Static publication depends on relative symlinks, hard links and atomic rename:
mount the complete data tree, not only a resolved current-release directory.

`state/identities.json` records the managed user/group names, numeric IDs and
memberships; `state/identities.log` records identity operations. On replacement,
the entrypoint restores the recorded accounts before starting services. A
numeric/name collision stops initialization for correction. It does not
recursively chown the dataset. Preserve these files alongside the data.

Bootstrap seeds missing nginx/systemd distribution files, restores local
identities and selected services, and validates nginx before launch. After
those services are restored, `getbible-image-update.service` applies a new or
previously unapplied image release to management services and enabled endpoints.
An already applied image skips that work on restart. Image application does not
fetch Bible data, scan its contents, change DNS or request certificates; normal
sync timers retain their existing schedules.

## 7. Updates, backup and recovery

Select a numbered image release in `.env`, or deliberately use `latest`, then:

Run these commands on the Docker host. If you are in the container's shell,
run `exit` first:

```sh
docker compose pull
docker compose up -d
docker compose exec --user root getbible getbible doctor
docker compose exec --user root getbible getbible status
```

`latest` follows accepted pull-request merges into `main` and changes locally
when pulled and recreated. Numbered tags remain fixed. Image replacement
restarts the system, then automatically refreshes the dashboard, telemetry and
enabled endpoints. Runtime updates use the newest bundled patch of the selected
Python family, with readiness, graceful nginx reload, drain and retained
generations for rollback. No additional update command is required after a
successful image refresh.

`getbible status` shows the image release, last applied release and update state.
The durable record is `/var/lib/getbible/state/image-update.conf`; `APPLIED_VERSION`
advances only after successful application. A failed update preserves serving
runtime generations and reports the cause. Resolve it and run `getbible update`
inside the root container shell to retry. `getbible doctor` is diagnostic.
See [UPDATING.md](UPDATING.md).

Traffic history is retained. Before starting the collector, updates inspect the
stored schema version and automatically migrate supported older schemas, including
schema 1 to 2, after a protective backup under `/var/backups/getbible/telemetry`.
Reporting records and ingestion cursors are preserved. The current
schema needs no migration. Unknown or newer schemas remain untouched and report a
failure. Updating never resets reporting history or rewrites Bible source files.

For a consistent simple backup, stop the container cleanly and archive the
whole persistent parent with numeric ownership, ACLs, extended attributes,
hard links and symlinks preserved. For the default path, choose a new backup
filename and run as an authorized host operator:

```sh
docker compose stop
sudo tar --numeric-owner --acls --xattrs -C /srv -cpf /srv/getbible-backup.tar getbible-data
sudo chmod 0600 /srv/getbible-backup.tar
docker compose up -d
```

Store a copy outside the Docker host, together with the matching Compose file,
protected `.env` and selected image version/digest. The archive includes
credentials. On a replacement host, restore into an empty target location
while the container is stopped, preserving numeric ownership, then authenticate
Docker, restore the deployment files and start the selected image. Do not
overwrite a running installation with archive extraction.

Verify after replacement: domain discovery, access/token behavior, unchanged
endpoint public keys, published symlinks, service owners, active runtime
versions, scheduled timers, custom pages and logs. Use `getbible runtime DOMAIN
ENDPOINT rollback` for an application generation rollback. Image rollback
selects the prior image tag and may also require the matching configuration
backup if newer persisted settings are incompatible.

## 8. Build and acceptance for maintainers

The production Compose file contains `image:` and no `build:`. The repository
Dockerfile installs OS packages and builds the reviewed runtime bundle. The
[image workflow](../.github/workflows/docker.yml) starts only for a push to
`main`, then verifies that a pull request was actually merged at that commit.
Pull-request commits, feature branches, direct unmerged pushes, Git tags and
manual dispatches do not build or publish images. Source, native deployment
and dashboard checks still run on pull requests before merge.

Each accepted main merge builds once per architecture. Both AMD64 and ARM64
must pass the complete image, offline runtime, service, proxy and persistence
acceptance tests. Publication loads those exact tested images and publishes
their commit-SHA tags and multi-architecture manifest. It does not
rebuild them in the publication jobs.

The tracked [VERSION](../VERSION) file controls the release number. Every
accepted main merge publishes that immutable number and `latest` from the same
tested images. Operators can pin a numbered tag indefinitely or follow `latest`.
The first release using this workflow is `2.0.0`. Each subsequent main merge
requires a greater version; unchanged or lower versions stop before the image
build. No Git tag or version in a commit message is needed.

| Change | Image publication after merge and acceptance |
| --- | --- |
| Add `VERSION` containing `2.0.0` | `2.0.0`, `latest` and commit-SHA tags, all from the same tested images |
| Merge with unchanged or lower `VERSION` | Validation fails; no image build or publication |
| Increase `VERSION` to a reviewed number | Publish that immutable number, `latest` and commit-SHA tags |
| Open or update a pull request | Source checks and disposable Docker upgrade acceptance; no image publication |

The main build/publication pipeline is serialized and an active run is not
cancelled by a newer merge. Up to 100 pending runs are queued, so a newer merge
does not replace a waiting version-release build. Before moving `latest`, the
workflow verifies that its commit is still the main head. An older run or rerun cannot replace a
newer main image; the previous `latest` remains available until a current main
image passes acceptance. Registry/API errors stop publication, and an existing
numbered image is never overwritten. Retrying publication may reuse that
number only when its complete manifest exactly matches the accepted image;
a conflicting manifest stops the job. Use a new version for a changed numbered
release rather than deleting or recreating an existing one.

GHCR publication requires the organization to permit package publishing and
the package to grant the intended pull access. Manage repository and package
visibility in GitHub settings; the workflow does not check or change either.
Native ARM64 runners must also be available under the organization's GitHub
Actions policy. Wait for the
merged commit's publication jobs to succeed before pulling its new images.
Endpoint `v2`/`v3` names are independent API contracts, not image versions.

### Choose the release version

The pull-request template asks **Which version should this merge release?**
Answer with one plain-text line in the PR description, for example:

```text
Release-Version: 2.0.1
```

The **Release version** check shows the current main version, proposed version
and the next patch, minor and major choices in its Actions summary. It fails
if the answer is missing, repeated, invalid or different from the committed
`VERSION`. It also checks that the number is greater than current main and that
the Dockerfile, Compose and environment defaults agree. Editing the PR
description or pushing a commit reruns this check without building an image.
GitHub's native PR templates are Markdown prompts, rather than interactive
issue forms; the workflow supplies the validation and current version details.

Use semantic versioning: patch for compatible fixes, minor for compatible new
features and major for breaking changes. A helper updates `VERSION` and all
three deployment defaults together:

```sh
# Choose one, run it in the source checkout, then commit the changed files:
python3 scripts/release-version.py set patch
python3 scripts/release-version.py set minor
python3 scripts/release-version.py set major
python3 scripts/release-version.py set 2.1.0
```

Increment commands use the version in the checkout; the explicit form accepts
your chosen number. Copy the resulting `Release-Version:` line into the PR
description and review the version change with the code. Published numbered
images remain available when a newer number becomes `latest`. Documentation
examples show sample releases; the tracked deployment defaults carry the
current release number.

The workflow reports a failing check for an unanswered version question. To
make GitHub itself disable merging until it passes, a maintainer must select
the **Release version** job as a required status check in the repository's
existing merge rules. This source change does not alter repository rules.
The main image workflow independently repeats version validation against the
actual previous main commit, so a stale PR or bypassed review check cannot
reuse a release number. If another release merged first, update the branch
and choose a higher number before merging.

See [GitHub's PR template documentation](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/creating-a-pull-request-template-for-your-repository)
and [semantic versioning](https://semver.org/) for the underlying conventions.

On a disposable compatible Docker host, maintainers can run the same image
acceptance locally after installing HAProxy and the test tools:

```sh
docker build -t getbible-api-test:ci .
tests/integration/docker.sh
```

This is a maintainer test command, not part of production installation. The
test uses its own fixture data and Compose project, boots systemd, exercises
offline query/search deployment and HAProxy, then recreates the container and
checks persistent identities, keys and behavior. It makes no Cloudflare or
certificate requests.

Acceptance must establish actual systemd startup, runtime readiness, resource
controls, graceful stop and recreation with preserved accounts/data. The
external route also needs the version-specific OPNsense/Cloudflare checks in
[OPNSENSE_HAPROXY.md](OPNSENSE_HAPROXY.md). Automated local tests do not claim
that a private registry package has been published or a customer's firewall
has been changed; confirm the corresponding workflow and deployment results.

## Primary references

- [GitHub private container registry and authentication](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [Publishing images with GitHub Actions](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)
- [Docker Compose service configuration](https://docs.docker.com/reference/compose-file/services/)
- [Docker container resource constraints](https://docs.docker.com/engine/containers/resource_constraints/)
- [systemd container interface](https://systemd.io/CONTAINER_INTERFACE/)
- [Linux cgroup-v2 memory accounting](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)

### Selective application and serving health

`getbible update --plan` shows management, runtime-version, MCP and static software
targets. `getbible update --select` opens the checklist; `--target ID` and
`--targets ID,ID` provide exact noninteractive subsets. An empty `--targets ''`
changes nothing. Automatic image application uses the same planner with changed
targets, leaving unchanged workers alone. `APPLIED_VERSION` advances only when
all required targets are current; `partial` means required changes were skipped,
and failed/interrupted targets remain retryable. See [UPDATING.md](UPDATING.md).

The container health check verifies selected query/search generations, MCP and an
enabled dashboard, as well as nginx. Missing selected releases fail readiness;
rejected/unselected candidates do not. An old healthy serving generation can keep
the container available during a failed upgrade without making the upgrade
complete. Whole-container replacement still involves the configured graceful
shutdown and startup, not a zero-downtime rolling cluster.
