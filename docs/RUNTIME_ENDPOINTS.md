# Runtime endpoints

A runtime endpoint is a Python service built on the getBible librarian,
running as its own system user in an immutable release, behind a systemd
socket, proxied and cached by nginx. Two kinds exist today, one instance of
each per server:

| Kind | Domain (typical) | Route | Librarian call |
| --- | --- | --- | --- |
| `query` | `query.getbible.net` | `GET /v2/{translation}/{reference}` | `select()` |
| `search` | `search.getbible.net` | `GET|POST /v2/{translation}/{search string}` | `search()` (and `select()` when the string is a reference) |

Both read the Bible files from a local folder, normally the data root of the
static endpoint that serves `api.getbible.net`, so nothing calls the public
API over the network. The version segment (`v2`) is the Bible data version;
the librarian only understands `v2` today, and the deploy refuses anything
else until it grows.

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
translation's actual scripture can be read), publish `/openapi.json` and serve
their documentation page at `/`. Search additionally exposes `/probez`, which
opens the search corpus and executes a bounded search through the librarian;
deployment checks it before activation. Use it for deliberate monitoring,
rather than repeatedly invoking the more expensive check as liveness.

## How a runtime endpoint is deployed

1. A system user `getbible-<kind>` (no shell, no home) in the
   `getbible-readers` group.
2. A unique root-owned release under `/opt/getbible/<kind>/releases/`
   with a virtual environment referencing a separately managed CPython
   interpreter and standard library under `/opt/getbible/python/`. The
   reviewed interpreter catalog is checksum-verified; package versions come
   from the kind's pinned requirements. Releases retain `.python-version`,
   `.python-distribution` and `packages.lock`. `current` points to the active
   code; successful installation never upgrades a serving release in place.
3. A generation under `/opt/getbible/<kind>/deployments/` stores the
   environment, gunicorn configuration, unit files and runtime settings
   together. `active` and `previous` identify the serving and rollback
   generations. `/etc/getbible/endpoints/<domain>/runtime.env` mirrors the
   active environment; both copies are root-only. Configuration changes
   create a new generation even when application code is unchanged.
4. Each generation has its own `getbible-<kind>-<generation>.socket` and
   `/run/getbible/<kind>/<generation>.sock` (`SocketGroup=www-data`, mode 0660).
   nginx continues using the old socket while the candidate starts.
5. Each generation's `.service` uses `Type=notify`; `ExecStartPre` runs the kind's
   check module (readiness and warm-up), then gunicorn with `preload_app`.
   The sandbox: `ProtectSystem=strict`, `ProtectHome`, no capabilities,
   `MemoryDenyWriteExecute`, private devices and tmp, read-only everything
   except the cache directory and the application log directory; plus the
   memory, CPU and task ceilings from the kind's manifest as a drop-in.
6. After candidate readiness, nginx switches `/` to the new socket using a
   validated graceful reload. Open/metered responses can use its GET/HEAD cache. It passes
   the request id and the token id upstream, never forwards the
   `Authorization` header, and replaces upstream CORS with its own.
7. Old services remain running until the pre-reload nginx workers exit.
   Worker identities include PID start times. A retirement service then stops
   the old backend; an old worker that remains alive delays retirement rather
   than losing its backend. Failures restore routing and prior deployment
   state, and manual rollback restores code plus runtime settings while
   preserving current authentication. Keep memory available for overlapping
   generations, particularly search warm-up.

## Commands

```sh
sudo ./getbible.sh deploy runtime --domain query.getbible.net --kind query --version v2 --repository /srv/getbible/api.getbible.net --access metered --warm kjv --python auto
sudo ./getbible.sh runtime versions
sudo ./getbible.sh runtime query.getbible.net update --python 3.14
sudo ./getbible.sh runtime query.getbible.net redeploy
sudo ./getbible.sh runtime query.getbible.net set WORKERS 4
sudo ./getbible.sh runtime query.getbible.net rollback
sudo ./getbible.sh status query.getbible.net
sudo ./getbible.sh logs query.getbible.net app
sudo ./getbible.sh logs query.getbible.net journal
```

The endpoint menu separates redeployment, application/dependency updates,
Python selection, rollback, logs and settings. Supported `set` keys:
`WORKERS`, `THREADS`, `WARM_TRANSLATIONS`, `DEFAULT_TRANSLATION`,
`DEFAULT_REFERENCE`, `ALLOWED_TRANSLATIONS`, `REPOSITORY`,
`REQUIRE_CHECKSUMS`, `CACHE_TTL`. Values are validated before activation.

`update DOMAIN` preserves the selected exact Python patch while applying
checked-out code and dependency changes. Explicit `runtime DOMAIN update`
adopts the reviewed latest patch in its current family; `--python` selects a
family or exact catalog patch. See [UPDATING.md](UPDATING.md) for migration,
failure recovery and operational validation.
