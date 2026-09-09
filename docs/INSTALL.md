# Installing on a server

Start with a fresh Ubuntu 24.04 or 26.04 host and sudo. Each domain can be
deployed staged and checked before public DNS points here, then go live later
(see `NEW_SERVER.md`).
The manager detects `/etc/os-release`, architecture, glibc, nginx capabilities
and available tools. `install-deps` uses `apt` on Debian/Ubuntu; on other Linux
distributions it reports the required packages for manual installation.
Live deployment requires systemd, a compatible nginx configuration layout,
and glibc 2.28 or newer on x86_64 or aarch64. Alpine/musl, other architectures
and non-Linux hosts are not supported runtime targets.

## 1. Clone

The manager runs as root from a root-owned Git checkout, and reads this
repository over SSH with a deploy key that only root holds. Set the key up
once; the first clone and every later `self-update` use it.

As root (`sudo su -`), generate the manager repository's key and show its public half:

```sh
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519
cat /root/.ssh/id_ed25519.pub
```

Add the public key under **getbible/api > Settings > Deploy keys > Add deploy
key**, leaving **Allow write access** unchecked
([GitHub: managing deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)).
A deploy key belongs to one repository. Every static endpoint gets a
separate key for its data repository from the tool, including endpoints
sharing the same domain. Never reuse root's manager key for these endpoints.

Tell SSH to use that key for GitHub by adding this to `/root/.ssh/config`
(create the file if it does not exist, mode `0600`):

```
Host github.com
        Hostname github.com
        IdentityFile=/root/.ssh/id_ed25519
```

Then clone:

```sh
sudo git clone git@github.com:getbible/api.git /opt/getbible/api
cd /opt/getbible/api
```

The first connection shows GitHub's host-key fingerprint; compare it with
[GitHub's published fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
before answering yes. Every `sudo git ...` and `sudo ./getbible.sh ...` runs
as root and picks up the same key through `/root/.ssh/config`, so nothing
else needs configuring.

The checkout is owned by root on purpose: code that root executes must not be
writable by a login user. Updating the manager is `sudo ./getbible.sh
self-update` (or **Update manager script** in the menu); applying the checkout
to hosted domains is the separate `update [DOMAIN]` action. See
[UPDATING.md](UPDATING.md).

## 2. Dependencies and first run

```sh
sudo ./getbible.sh install-deps     # nginx, certbot (+ dns-cloudflare plugin), python3-venv, whiptail, rsync, git, acl, ...
sudo ./getbible.sh doctor           # what the host looks like
sudo ./getbible.sh runtime versions # reviewed CPython versions and builds
sudo ./getbible.sh                  # the menu
```

The first run creates `/etc/getbible` with the global configuration, the
`getbible-readers` and `getbible-notify` groups, the log rotation timer and the
helper programs under `/usr/local/lib/getbible`.
`install-deps` enables and starts `certbot.timer` for automatic renewal checks.

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

## 4. Deploy domains

A domain is a host name (one vhost, one certificate); its endpoints are its
version folders (`/v2/`), or the domain root when it has none. Deploy a new
domain > Static or Runtime. Both walk-throughs first say what they will ask
and what happens afterwards, then ask for the domain and **Go live now?**

- **Go live now**: the domain takes over its name at once. A certificate
  is requested from Let's Encrypt as soon as the HTTP vhost is up, and once
  its Cloudflare mode is set to `dns` or `proxied` (Domain > Cloudflare
  settings; new domains start with `off`) its DNS records are pointed at
  this server on every apply.
- **Stage it**: everything is installed and verified (data, services,
  nginx with a self-signed placeholder certificate) but no certificate is
  requested and DNS is not changed, so whatever serves the name today keeps
  serving. Main menu > Go live, or Domain > Go live, switches it later.
  Settings > New domains chooses the default answer; `NEW_SERVER.md`
  walks through setting up a fresh server this way.

The static walk-through then asks for the first endpoint (a version folder
such as `v2`, or nothing for the domain root), the git repository, branch,
source folder, file types, access mode and check schedule, and prints the
endpoint's deploy key to add to that repository as read-only. Adding another
endpoint creates its own key, even when it shares this domain; show it later
with `deploy-key DOMAIN ENDPOINT`. The runtime walk-through asks for the
kind (query or search), the version (from those the kind's implementations
declare) and whether it lives under `/v2/` or at the domain root, and the
folder that holds the Bible files, and warns when that folder does not hold
the version yet. When a Cloudflare API token is stored, both ask whether the
domain is a Cloudflare zone this tool should manage (off, dns or proxied).
The menu checks on start that nginx, certbot, rsync, git, ssh-keygen and
openssl are present and offers to install them. Details:
`STATIC_ENDPOINTS.md`, `RUNTIME_ENDPOINTS.md`.

Every domain then has its documentation pages: the domain page at `/`, an
endpoint page at `/vN/` and an OpenAPI document at `/vN/openapi.json`, all
public. Domain > Pages and OpenAPI shows where each comes from and lets you
take one over or point it at the repository. Every domain serves the getBible
icons from the repository's `img/` folder (favicon and page logo); Settings >
Icons replaces them. Details: `PAGES.md`.

Each domain has **one certificate shared by all its endpoints**. The default
is Certbot HTTP-01 through nginx's port-80 challenge directory; it requires
public DNS to reach this server and needs no Cloudflare account or token.
Cloudflare DNS-01 is optional: select it explicitly, or automatic validation
selects it for a domain managed through Cloudflare when its token and the
`certbot-dns-cloudflare` plugin are available. DNS-01 works before DNS points
here, so a staged domain can already hold its real certificate: Domain >
Certificate > Issue. When a live deploy's certificate request fails (DNS not
yet here, port 80 blocked), the domain serves HTTP only: ACME challenges
are answered and normal requests redirect to HTTPS. Fix the cause and use
Domain > Certificate > Issue.

Certbot stores the certificate under `/etc/letsencrypt/live/<domain>/` and
renews it automatically with the method recorded when it was issued. The
installed deploy hook validates nginx and reloads it after a successful
renewal. Adding endpoints reuses the domain certificate; it does not request
another one. Staged domains use a temporary self-signed certificate until a
Let's Encrypt certificate is issued.

## Where things live

| Path | Holds |
| --- | --- |
| `/opt/getbible/api/` | root-owned manager Git checkout, updated with `self-update` |
| `/root/.ssh/id_ed25519`, `/root/.ssh/config` | root's deploy key for this repository and the SSH configuration that selects it |
| `/etc/getbible/getbible.conf` | global defaults (access mode, limits, caching, schedule, log retention, deploy mode, certificate method and contact email, HSTS, the public addresses used for DNS records, whether the favicon and logo are the repository's or yours) |
| `/etc/getbible/favicon.ico`, `logo.EXT` | a favicon or logo of yours that replaces the repository's for every domain |
| `/etc/getbible/telegram.conf`, `cloudflare.conf` | notification and Cloudflare credentials (root only) |
| `/etc/getbible/certbot-cloudflare.ini` | the Cloudflare token as certbot's DNS-01 plugin reads it (root only, written from `cloudflare.conf`) |
| `/etc/getbible/placeholder-certs/<domain>/` | the self-signed certificate of a staged domain (removed at go-live) |
| `/etc/letsencrypt/live/<domain>/` | the Let's Encrypt certificate and private key shared by every endpoint on the domain |
| `/etc/letsencrypt/renewal-hooks/deploy/getbible-reload-nginx.sh` | validates and reloads nginx after certificate renewal |
| `/etc/getbible/endpoints/<domain>/` | `endpoint.conf` (the domain, including `LIVE=true|false`), `versions/<label>.conf` (its endpoints: repository or service settings, page and OpenAPI sources), `tokens.json`, `runtime-<label>.env` |
| `/var/www/getbible/<domain>/` | the domain page, endpoint pages and OpenAPI documents (generated, or maintained by you), `favicon.ico`, `img/` (the icons the pages show), `versions.json` |
| `/etc/nginx/sites-available/<domain>.conf` | the rendered vhost (`conf.d/getbible-*.conf`, `snippets/getbible/`, `getbible/` hold the shared pieces) |
| `/srv/getbible/<domain>/<label>` | the live tree of a static endpoint (a symlink to a release under `releases/<label>/`) |
| `/opt/getbible/<kind>/<label>/current` | the live release of a runtime endpoint (a symlink under `releases/`) |
| `/opt/getbible/<kind>/<label>/active`, `previous`, `deployments/` | active and previous generations, each with its own environment, service configuration and release reference |
| `/opt/getbible/python/` | managed CPython distributions with verified provenance; never upgraded in place |
| `/var/log/getbible/<domain>/` | `access.log`, `error.log`, `app/<label>.log` (runtime), `archive/` |
| `/var/lib/getbible/` | state, the ledger of installed files, sync users' homes |
| `/var/lib/getbible/sync/<user>/.ssh/` | separate deploy keys for each static endpoint and repository URL, plus the domain sync user's pinned repository host keys |
| `/var/backups/getbible/` | backup sets taken before every configuration change |

Every menu action has a command line equivalent (`./getbible.sh --help`), so
the same steps can be scripted or run from a timer.
