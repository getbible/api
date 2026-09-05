# Installing on a server

One Ubuntu (22.04 or 24.04) server, DNS for each endpoint domain pointing at
it, and a shell with sudo. Everything else is installed by the tool.

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
sudo ./getbible.sh                  # the menu
```

The first run creates `/etc/getbible` with the global configuration, the
`getbible-readers` and `getbible-notify` groups, the log rotation timer and the
helper programs under `/usr/local/lib/getbible`.

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
port 80 blocked) the endpoint stays HTTP-only; run "Re-apply configuration"
on the endpoint once that is fixed.

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
| `/var/log/getbible/<domain>/` | `access.log`, `error.log`, `app/app.log`, `archive/` |
| `/var/lib/getbible/` | state, the ledger of installed files, sync users' homes |
| `/var/backups/getbible/` | backup sets taken before every configuration change |

Every menu action has a command line equivalent (`./getbible.sh --help`), so
the same steps can be scripted or run from a timer.
