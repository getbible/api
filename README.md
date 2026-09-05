# getBible API

One script that deploys and maintains every public getBible API endpoint on
a server, securely and at high volume.

- **Static endpoints**: versioned trees of JSON, checksum and text files,
  synchronised from git repositories by isolated users with their own deploy
  keys, published as atomic hard-linked releases and served by nginx with
  open CORS, locked security headers, problem-document errors and
  compression.
- **Runtime endpoints**: the `query` (references to verses) and `search`
  (full-text search) services built on the getBible librarian, each an
  immutable release run by gunicorn as its own sandboxed user behind a
  separate systemd socket for each deployment. Candidates pass readiness before
  nginx switches traffic; old workers drain before their backend stops.
- **Access modes** per endpoint: open, metered (public budget per address,
  token holders unlimited) or token only, with bearer tokens issued from
  the menu.
- **Operations**: JSON logs of everything, size-based rotation with
  retention, analytics with total calls and unique callers, Telegram
  notifications for every change, Cloudflare integration, one-command
  updates after `git pull`, and a guided migration from a legacy setup.

```sh
sudo git clone https://github.com/getbible/api.git /opt/getbible/api
cd /opt/getbible/api
sudo ./getbible.sh install-deps
sudo ./getbible.sh
```

Ubuntu **24.04 and 26.04** are the deployment targets. The manager detects the
OS, architecture and capabilities; Debian/Ubuntu prerequisites use `apt`.
Other glibc Linux hosts need compatible tools, systemd and nginx installed
with their package manager. Managed runtimes cover x86_64 and aarch64 with
glibc 2.28 or newer.

Runtime CPython is installed under `/opt/getbible/python` from a reviewed,
SHA-256-verified catalog covering Python 3.12, 3.13 and 3.14. Interpreter,
standard library and virtual environments belong to the application, so
distro Python updates do not replace them. Updates are explicit:

```sh
sudo ./getbible.sh list
sudo ./getbible.sh runtime versions
sudo ./getbible.sh update query.getbible.net
sudo ./getbible.sh runtime query.getbible.net update --python 3.14
sudo ./getbible.sh runtime query.getbible.net rollback
```

Ordinary `update` applies reviewed application/package changes while retaining
the endpoint's exact Python patch. Explicit `runtime ... update` adopts the
catalog's latest patch in the selected family. Allow memory for both runtime
generations during upgrades. The kernel, glibc, nginx and systemd remain host
dependencies; plan their maintenance separately.

Documentation:

| Document | Contents |
| --- | --- |
| [docs/INSTALL.md](docs/INSTALL.md) | first setup, where things live |
| [docs/STATIC_ENDPOINTS.md](docs/STATIC_ENDPOINTS.md) | versions, synchronisation, serving |
| [docs/RUNTIME_ENDPOINTS.md](docs/RUNTIME_ENDPOINTS.md) | the query and search services |
| [docs/ACCESS_MODES.md](docs/ACCESS_MODES.md) | open, metered, token; budgets; tokens |
| [docs/LOGGING.md](docs/LOGGING.md) | logs, rotation, analytics |
| [docs/TELEGRAM.md](docs/TELEGRAM.md) | notifications |
| [docs/CLOUDFLARE.md](docs/CLOUDFLARE.md) | proxy modes, rules, real IP, origin pulls |
| [docs/UPDATING.md](docs/UPDATING.md) | updating and rolling back |
| [docs/ADDING_A_RUNTIME_KIND.md](docs/ADDING_A_RUNTIME_KIND.md) | the contract for a new runtime service |
| [docs/SECURITY.md](docs/SECURITY.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how it is put together |

Every menu action has a command line form: `./getbible.sh --help`. Tests:
`tests/run.sh` (lint, unit, command line) and `tests/run.sh --all` (plus
real nginx and gunicorn; needs nginx and root).

License: Apache 2.0.
