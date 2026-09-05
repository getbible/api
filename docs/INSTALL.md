# Installing on a server

Start with Ubuntu 24.04 or 26.04, DNS for each endpoint domain, and sudo.
The manager detects `/etc/os-release`, architecture, glibc, nginx capabilities
and available tools. `install-deps` uses `apt` on Debian/Ubuntu; on other Linux
distributions it reports the required packages for manual installation.
Live deployment requires systemd, a compatible nginx configuration layout,
and glibc 2.28 or newer on x86_64 or aarch64. Alpine/musl, other architectures
and non-Linux hosts are not supported runtime targets.

## 1. Clone

```sh
sudo git clone https://github.com/getbible/api.git /opt/getbible/api
cd /opt/getbible/api
```

The checkout is owned by root on purpose: code that root executes must not be
writable by a login user. Updating is `sudo git pull` followed by the Update
action (see `UPDATING.md`).

## 2. Dependencies and first run

```sh
sudo ./getbible.sh install-deps     # nginx, certbot, python3-venv, whiptail, rsync, git, acl, ...
sudo ./getbible.sh doctor           # what the host looks like
sudo ./getbible.sh runtime versions # reviewed CPython versions and builds
sudo ./getbible.sh                  # the menu
```

The first run creates `/etc/getbible` with the global configuration, the
`getbible-readers` and `getbible-notify` groups, the log rotation timer and the
helper programs under `/usr/local/lib/getbible`.

The rendered configuration adapts to the release. Ubuntu 26.04 ships the Rust
coreutils, whose `install -d` and `mv -T` differ from GNU's, so the tool creates
every directory level explicitly and switches symlinks with `rename(2)`. Ubuntu
24.04 ships nginx 1.24, which could reset connections with threaded file reads
in flight during a reload; `aio threads` is enabled only from nginx 1.25.4.

Runtime Python is separate from the host's management Python. First deployment
downloads a checksum-verified standalone CPython distribution and installs
packages into a new release. `auto` selects the reviewed 3.12 family on Ubuntu
24.04 and 3.14 on Ubuntu 26.04; `--python 3.13` or an exact catalog patch can
override it. The selected exact patch is recorded per endpoint. No timer
upgrades runtime Python or its packages, and host Python upgrades do not
replace either its interpreter or standard library.

Provide network access to GitHub release assets, the Python package index,
your data repositories, and configured certificate/Cloudflare/Telegram
services. Size runtime hosts for the old and candidate workers to coexist
during an update, plus release/interpreter storage. OS libraries, the kernel,
nginx and systemd still follow host maintenance policy.

## 3. Telegram (recommended first)

Settings > Telegram notifications: bot token and chat id. From then on every
action that changes files on the server sends a message: syncs, releases,
certificate renewals, log rotations, token changes.

## 4. Deploy endpoints

Deploy a new endpoint > Static or Runtime. The static walk-through asks for
the domain, the first version, the git repository, branch, source folder,
file types, access mode and check schedule; it then prints the deploy key to
add to the repository. The runtime walk-through asks for the kind (query or
search), the domain, the version and the folder that holds the Bible files.
Details: `STATIC_ENDPOINTS.md`, `RUNTIME_ENDPOINTS.md`.

Certificates are requested from Let's Encrypt automatically once the domain's
HTTP vhost is up. When certbot cannot reach Let's Encrypt (DNS not yet live,
port 80 blocked), HTTPS deployment is incomplete: HTTP serves ACME challenges
and redirects normal requests to HTTPS. Fix certificate issuance and run
"Re-apply configuration" before exposing the endpoint to clients.

## 5. Migrating an existing server

If the domains are already declared in another nginx file (for example
`sites-available/default`) or an old query service exists, System > Retire
the legacy setup shows what it found and, after confirmation, removes those
server blocks (backed up under `/var/backups/getbible`), retires the old unit
and reloads nginx. Deploy the new endpoints first, then migrate.

## Where things live

| Path | Holds |
| --- | --- |
| `/etc/getbible/getbible.conf` | global defaults (access mode, limits, caching, schedule, log retention) |
| `/etc/getbible/telegram.conf`, `cloudflare.conf` | notification and Cloudflare credentials (root only) |
| `/etc/getbible/endpoints/<domain>/` | `endpoint.conf`, `versions/*.conf`, `tokens.json`, `runtime.env` |
| `/etc/nginx/sites-available/<domain>.conf` | the rendered vhost (`conf.d/getbible-*.conf`, `snippets/getbible/`, `getbible/` hold the shared pieces) |
| `/srv/getbible/<domain>/<version>` | the live static tree (a symlink to a release under `releases/`) |
| `/opt/getbible/<kind>/current` | the live runtime release (a symlink under `releases/`) |
| `/opt/getbible/<kind>/active`, `previous`, `deployments/` | active and previous generations, each with its own environment, service configuration and release reference |
| `/opt/getbible/python/` | managed CPython distributions with verified provenance; never upgraded in place |
| `/var/log/getbible/<domain>/` | `access.log`, `error.log`, `app/app.log`, `archive/` |
| `/var/lib/getbible/` | state, the ledger of installed files, sync users' homes |
| `/var/backups/getbible/` | backup sets taken before every configuration change |

Every menu action has a command line equivalent (`./getbible.sh --help`), so
the same steps can be scripted or run from a timer.
