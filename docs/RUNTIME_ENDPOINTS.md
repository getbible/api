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
- Responses are the librarian's chapter-keyed object, with `Cache-Control:
  public, max-age=300` and an ETag; nginx caches them for the same time.

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
translation can be read), publish `/openapi.json` and serve their
documentation page at `/`.

## How a runtime endpoint is deployed

1. A system user `getbible-<kind>` (no shell, no home) in the
   `getbible-readers` group.
2. A release under `/opt/getbible/<kind>/releases/<stamp>-<inputs hash>/`
   with a virtual environment built from the kind's pinned
   `requirements.txt`, the shared `getbible_api_common` package and the
   kind's package; `current` is a symlink to the live release. A release is
   rebuilt only when its inputs (code, requirements, gunicorn template)
   change; the previous release is kept and used for rollback.
3. `/etc/getbible/endpoints/<domain>/runtime.env`, root-only, read by
   systemd: repository, version, cache directory, defaults, workers,
   threads, warm-up list.
4. `getbible-<kind>.socket` owns `/run/getbible/<kind>/gunicorn.sock`
   (`SocketGroup=www-data`, mode 0660): nginx never joins service groups and
   restarts never refuse connections.
5. `getbible-<kind>.service`: `Type=notify`, `ExecStartPre` runs the kind's
   check module (readiness and warm-up), then gunicorn with `preload_app`.
   The sandbox: `ProtectSystem=strict`, `ProtectHome`, no capabilities,
   `MemoryDenyWriteExecute`, private devices and tmp, read-only everything
   except the cache directory and the application log directory; plus the
   memory, CPU and task ceilings from the kind's manifest as a drop-in.
6. nginx proxies `/` to the socket with a response cache (GET/HEAD), passes
   the request id and the token id upstream, never forwards the
   `Authorization` header, and replaces upstream CORS with its own.
7. Activation waits for `/readyz` on the socket; when a new release does not
   come up, the symlink flips back and the previous release is restarted.

## Commands

```sh
getbible.sh deploy runtime --domain query.getbible.net --kind query [--version v2] [--repository /srv/getbible/api.getbible.net] [--access metered] [--warm kjv]
getbible.sh status query.getbible.net
getbible.sh logs query.getbible.net app        # the application's JSON log
getbible.sh logs query.getbible.net journal    # systemd journal
```

Endpoint menu: restart, journal, rebuild the release, settings (workers,
threads, warm-up list, default and allowed translations, repository folder).
