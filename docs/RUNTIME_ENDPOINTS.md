# Runtime domains and their endpoints

A runtime domain serves Python services built on the getBible librarian,
running as their own system user in immutable releases, behind systemd
sockets, proxied and cached by nginx. Two kinds exist today, one domain of
each per server:

| Kind | Domain (typical) | Route | Librarian call |
| --- | --- | --- | --- |
| `query` | `query.getbible.net` | `GET /v2/{translation}/{reference}` | `select()` |
| `search` | `search.getbible.net` | `GET|POST /v2/{translation}/{search string}` | `search()` (and `select()` when the string is a reference) |

Both read the Bible files from a local folder, normally the data root of the
static domain that serves `api.getbible.net`, so nothing calls the public
API over the network.

## Endpoints: one service per version

A runtime domain's endpoints are its versions. Every endpoint is its own
service: its own release and generations under `/opt/getbible/<kind>/<label>/`,
its own units (`getbible-<kind>-<label>-<generation>`), sockets
(`/run/getbible/<kind>/<label>/`), librarian cache
(`/var/cache/getbible/<kind>/<label>/`), environment file
(`/etc/getbible/endpoints/<domain>/runtime-<label>.env`), application log
(`/var/log/getbible/<domain>/app/<label>.log`) and settings
(`/etc/getbible/endpoints/<domain>/versions/<label>.conf`). nginx routes
`/v2/` to the v2 service and `/v3/` to the v3 service; `/`, the short forms
(`/John3:16`), `/healthz` and `/readyz` go to the **default endpoint**
(Domain > Endpoints > Choose the default; `version default DOMAIN vN`).

Which versions a kind can serve is declared by its implementations under
`src/apps/`: `src/apps/<kind>/manifest.conf` lists the versions that code
supports (`SUPPORTED_VERSIONS`); a version that needs code of its own lives in
`src/apps/<kind>-<version>/` with a manifest of its own. The tool never
hard-codes a version: the deploy walkthrough and `version add` offer what the
implementations declare, and a version nobody implements is refused. Adding
`v3` to a running domain is one action (Domain > Endpoints > Add a version):
its release is built, its service started and checked for readiness, nginx
switches to the new configuration in one reload, and the domain's pages and
`versions.json` list the new endpoint. Removing an endpoint stops its service
and deletes its releases and cache; the last endpoint cannot be removed
(remove the domain instead).

A domain may instead serve a **single version at its root** (deploy with
`--root`, or answer yes to "Serve it at the domain root"): the endpoint's
label is `root`, `https://search.getbible.net/kjv/faith%20hope` is the route,
and nginx rewrites every request to the version the service speaks and
strips it from the service's redirects again. Such a domain cannot add other
versions later; a domain with version folders can.

Installations from before endpoints had their own records (a `VERSION` key
and the settings in `endpoint.conf`, one service under
`/opt/getbible/<kind>` with units `getbible-<kind>-<generation>`) are
migrated on first use: the tool records the endpoint with `LAYOUT=legacy`,
copies the settings into its record and keeps every path, unit and socket
where it is. Nothing running is moved or restarted by the migration. New
endpoints added to such a domain use the versioned layout.

## The query endpoint

- `/v2/{translation}/{reference}` is the only data route. It takes no
  parameters; a query string answers `400 parameters_not_accepted`.
- References follow the librarian's grammar; several are joined with `;`.
  One unresolvable reference rejects the whole request with `400
  invalid_reference` (the librarian's behaviour, kept on purpose).
- Every shorter form is a `301` to the canonical route: `/v2` and
  `/v2/{translation}` go to the default reference (`Mat7:7`), `/{reference}`
  and `/{translation}/{reference}` fill in `kjv` for a missing or unknown
  translation and the default reference for an unresolvable one.
- Responses are the librarian's chapter-keyed object, with an ETag and public
  caching in open/metered mode. Token-only responses use `private, no-store`
  and bypass both reads and writes of nginx's shared response cache.

## The search endpoint

- The search string is the last path segment; `/v2/{search string}` without
  a translation redirects to the default translation.
- Filters travel as query parameters or as a JSON body; GET and POST both
  work (`Content-Type: application/json` for bodies). Precedence: path, then
  query string, then body, then the endpoint's configured defaults.
- `q` and `translation` may travel in the query string or body when they are
  not in the path. A request without a search string answers `400
  missing_search`. Unknown or repeated parameters answer `400`.
- A search string that parses as a scripture reference returns that
  scripture in the same envelope with `query.kind = "reference"`.
- Search work is bounded by the librarian's deadline (5 s) and work budget,
  by a per-worker concurrency gate that answers `503 busy` at capacity (a
  smaller share for expensive criteria), by gunicorn's worker timeout and by
  nginx's proxy timeout.
- The translations named in the warm-up list (default `kjv`) are indexed
  before workers fork, so the first search after a restart is fast.

Both endpoints answer `/healthz` (liveness) and `/readyz` (the default
translation's actual scripture can be read). Every endpoint publishes its
documentation page at `/vN/` and its OpenAPI document at `/vN/openapi.json`;
the domain page at `/` lists the endpoints and `/versions.json` maps them to
their documents (see [PAGES.md](PAGES.md)). Search additionally exposes
`/probez`, which opens the search corpus and executes a bounded search
through the librarian; deployment checks it before activation. Use it for
deliberate monitoring, rather than repeatedly invoking the more expensive
check as liveness.

## How an endpoint is deployed

1. A system user `getbible-<kind>` (no shell, no home) in the
   `getbible-readers` group, shared by the kind's endpoints.
2. A unique root-owned release under `/opt/getbible/<kind>/<label>/releases/`
   with a virtual environment referencing a separately managed CPython
   interpreter and standard library under `/opt/getbible/python/`. The
   reviewed interpreter catalog is checksum-verified; package versions come
   from the implementation's pinned requirements. Releases retain
   `.python-version`, `.python-distribution` and `packages.lock`. `current`
   points to the active code; successful installation never upgrades a
   serving release in place.
3. A generation under `/opt/getbible/<kind>/<label>/deployments/` stores the
   environment, gunicorn configuration, unit files, a copy of the endpoint's
   record and its release reference together. `active` and `previous`
   identify the serving and rollback generations. The endpoint's
   `runtime-<label>.env` mirrors the active environment; both copies are
   root-only. Configuration changes create a new generation even when
   application code is unchanged.
4. Each generation has its own `getbible-<kind>-<label>-<generation>.socket`
   and `/run/getbible/<kind>/<label>/<generation>.sock` (`SocketGroup=www-data`,
   mode 0660). nginx continues using the old socket while the candidate starts.
5. Each generation's `.service` uses `Type=notify`; `ExecStartPre` runs the
   implementation's check module (readiness and warm-up), then gunicorn with
   `preload_app`. The sandbox: `ProtectSystem=strict`, `ProtectHome`, no
   capabilities, `MemoryDenyWriteExecute`, private devices and tmp, read-only
   everything except the endpoint's cache directory and the application log
   directory; plus the memory, CPU and task ceilings from the manifest as a
   drop-in.
6. After every candidate of the domain is ready, nginx switches to the new
   sockets using one validated graceful reload. Open/metered responses can
   use its GET/HEAD cache. It passes the request id and the token id
   upstream, never forwards the `Authorization` header, and replaces upstream
   CORS with its own.
7. Old services remain running until the pre-reload nginx workers exit.
   Worker identities include PID start times. A retirement service then stops
   the old backend; an old worker that remains alive delays retirement rather
   than losing its backend. Failures restore routing and prior deployment
   state of every endpoint, and manual rollback restores an endpoint's code
   plus settings while preserving the domain's current authentication. Keep
   memory available for overlapping generations, particularly search warm-up.

## Commands

```sh
sudo ./getbible.sh deploy runtime --domain query.getbible.net --kind query --version v2 --repository /srv/getbible/api.getbible.net --access metered --warm kjv --python auto
sudo ./getbible.sh deploy runtime --domain search.getbible.net --kind search --version v2 --root
sudo ./getbible.sh version add query.getbible.net v3 [--repository PATH] [--warm kjv] [--python 3.14]
sudo ./getbible.sh version default query.getbible.net v3
sudo ./getbible.sh version remove query.getbible.net v2
sudo ./getbible.sh runtime versions
sudo ./getbible.sh runtime query.getbible.net update --python 3.14        # every endpoint
sudo ./getbible.sh runtime query.getbible.net v3 update --python 3.14     # one endpoint
sudo ./getbible.sh runtime query.getbible.net redeploy
sudo ./getbible.sh runtime query.getbible.net v2 set WORKERS 4
sudo ./getbible.sh runtime query.getbible.net v2 rollback
sudo ./getbible.sh status query.getbible.net
sudo ./getbible.sh logs query.getbible.net app v2
sudo ./getbible.sh logs query.getbible.net journal v2
```

The endpoint name may be left out of `set` and `rollback` when the domain has
one endpoint. The domain menu separates redeployment, application/dependency
updates, Python selection, rollback, logs and settings, each asking which
endpoint when there is more than one, and has an Endpoints screen to add or
remove a version and choose the default. Supported `set` keys: `WORKERS`,
`THREADS`, `WARM_TRANSLATIONS`, `DEFAULT_TRANSLATION`, `DEFAULT_REFERENCE`,
`ALLOWED_TRANSLATIONS`, `REPOSITORY`, `REQUIRE_CHECKSUMS`, `CACHE_TTL`. Values
are validated before activation.

`update DOMAIN` preserves each endpoint's selected exact Python patch while
applying checked-out code and dependency changes. Explicit `runtime DOMAIN
update` adopts the reviewed latest patch in each endpoint's current family;
`--python` selects a family or exact catalog patch. See
[UPDATING.md](UPDATING.md) for migration, failure recovery and operational
validation.
