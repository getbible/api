# Adding a runtime kind, or a new version of one

A runtime kind is a directory under `src/apps/` that the runtime type
discovers by its manifest. The suite fails when any required file is
missing, so the contract is enforced, not just described.

```
src/apps/<kind>/
  manifest.conf                 what the deployer needs to know
  pyproject.toml                package metadata (depends on getbible-api-common)
  requirements.txt              exact pins for the whole dependency tree
  openapi.json.tmpl             served at /<version>/openapi.json (variables below)
  docs.html.tmpl                served at /<version>/ (variables below)
  getbible_<kind>_api/
    __init__.py
    config.py                   Settings.from_environment()
    app.py                      create_app(settings=None) -> Flask
    wsgi.py                     app = create_app()
    check.py                    main() -> 0, run by ExecStartPre
tests/python/test_<kind>_app.py
```

## Versions and implementations

Every endpoint of a runtime domain is one version served by its own service.
Which versions a kind can serve is declared by its implementation
directories, never by the tool:

- `src/apps/<kind>/` is the base implementation. Its `SUPPORTED_VERSIONS`
  lists every version this code serves (`v2`, or `v2,v3` when the same code
  speaks both).
- `src/apps/<kind>-<version>/` is an implementation for one version that
  needs code of its own (a `v3` built on a different librarian, say). It is
  a complete kind directory with its own manifest (`KIND=<kind>`,
  `SUPPORTED_VERSIONS=<version>`, `PACKAGE=` its own package name), pinned
  requirements, templates and `tests/python/test_<kind>_<version>_app.py`.
  When both directories claim a version, the version-specific one wins.

The tool offers the union of the declared versions when a domain is
deployed or a version is added, builds each endpoint's release from its
implementation directory, and refuses a version nobody implements. Nothing
else is needed: adding `src/apps/query-v3/` makes "Add a version: v3"
appear for every query domain.

## manifest.conf

```
KIND=<kind>                     directory name, unit name suffix, user name suffix
DESCRIPTION=...                 shown in the deploy menu
PACKAGE=getbible_<kind>_api
WSGI=getbible_<kind>_api.wsgi:app
CHECK=getbible_<kind>_api.check
ENV_PREFIX=<KIND>               environment prefix for the service's own settings
DEFAULT_VERSION=v2              offered first when a domain is deployed
SUPPORTED_VERSIONS=v2,v3        comma separated; the versions this directory serves
ROUTE=GET /{version}/{translation}/{reference}
                                the route shown on the domain page; {version} is the endpoint
METHODS=GET|HEAD|OPTIONS        nginx method regex; add POST when bodies are accepted
MAX_BODY=1k                     nginx client_max_body_size
CACHE_SECONDS=300               nginx proxy cache and default Cache-Control
WORKERS=4  THREADS=4            gunicorn defaults
TIMEOUT_START=90  TIMEOUT_STOP=30
MEMORY_HIGH=384M  MEMORY_MAX=512M  CPU_QUOTA=200%  TASKS_MAX=64  NOFILE=4096
WARM_TRANSLATIONS=              comma separated, warmed before workers fork
```

## What the application must do

Use `getbible_api_common`:

- `install_request_hooks(app, service_settings, logger)` for request ids,
  timing, headers and the JSON access log;
- `register_error_handlers(app, logger)` so every failure is a problem
  document; raise `ProblemError(status, code, detail)` for your own;
- `register_health(app, bible, default_translation, logger)` for
  `/healthz` and `/readyz`;
- `json_response(app, payload, cache_seconds=...)` for data and
  `redirect_permanent(location)` for short forms;
- `LibrarianSettings.from_environment(cache_dir)` and
  `ServiceSettings.from_environment(PREFIX)` for configuration; read
  anything else from the environment with `env_int`, `env_bool`, `env_str`.

Rules: use the librarian's public API only; never wrap or reimplement its
behaviour; keep the kind's routes separate from the other kinds'; never log
a bearer token; version segments are validated against `SUPPORTED_VERSIONS`.
The service always speaks its version in the path (`/v2/...`); when a
domain serves it at the root, nginx adds the segment on the way in and
strips it from redirects on the way out, so the application needs no
root-mode code.

## Templates

`openapi.json.tmpl` and `docs.html.tmpl` are rendered with `DOMAIN`,
`VERSION` (the version the service speaks), `PREFIX` (the public path of the
endpoint: `/v2/`, or `/` for a root endpoint), `VERSION_PATH` (`/v2`, or `/`),
`IS_ROOT`, `DEFAULT_TRANSLATION`, `DEFAULT_REFERENCE`, `TOKEN_REQUIRED`,
`ACCESS_MODE_LABEL`, `ACCESS_HTML`, `CACHE_SECONDS`, `CSS` (the docs page
stylesheet), `HEAD_ICONS` (the icon links of the page head), `LOGO_URL` and
`ICON_URL` (the images at the top and the foot of the page, empty when the
domain shows none), `FAVICON` (whether the domain serves one) and
`OPENAPI_URL` (the document's address, empty when the endpoint has none). Write public paths
with `PREFIX` and guard version-specific text with `{{#UNLESS IS_ROOT}}` so
the page and the document stay right for a root endpoint. The rendered
OpenAPI document must be valid JSON; the deploy checks it. Both are
regenerated on every apply unless the operator has taken them over (see
[PAGES.md](PAGES.md)).

## Environment

`src/types/runtime/templates/env.tmpl` renders the service environment. A
new kind that needs extra variables adds them to that template guarded by an
`{{#IF IS_<KIND>}}` block and sets `IS_<KIND>` in `rt_render_env` in
`src/types/runtime/type.sh`.
