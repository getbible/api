# Adding a runtime kind

A runtime kind is a directory under `src/apps/` that the runtime type
discovers by its manifest. The suite fails when any required file is
missing, so the contract is enforced, not just described.

```
src/apps/<kind>/
  manifest.conf                 what the deployer needs to know
  pyproject.toml                package metadata (depends on getbible-api-common)
  requirements.txt              exact pins for the whole dependency tree
  openapi.json.tmpl             served at /openapi.json (variables below)
  docs.html.tmpl                served at / (variables below)
  getbible_<kind>_api/
    __init__.py
    config.py                   Settings.from_environment()
    app.py                      create_app(settings=None) -> Flask
    wsgi.py                     app = create_app()
    check.py                    main() -> 0, run by ExecStartPre
tests/python/test_<kind>_app.py
```

## manifest.conf

```
KIND=<kind>                     directory name, unit name suffix, user name suffix
DESCRIPTION=...                 shown in the deploy menu
PACKAGE=getbible_<kind>_api
WSGI=getbible_<kind>_api.wsgi:app
CHECK=getbible_<kind>_api.check
ENV_PREFIX=<KIND>               environment prefix for the service's own settings
DEFAULT_VERSION=v2
SUPPORTED_VERSIONS=v2           comma separated; the deploy refuses others
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

## Templates

`openapi.json.tmpl` and `docs.html.tmpl` are rendered with `DOMAIN`,
`VERSION`, `DEFAULT_TRANSLATION`, `DEFAULT_REFERENCE`, `TOKEN_REQUIRED`,
`ACCESS_MODE_LABEL`, `ACCESS_HTML`, `CACHE_SECONDS` and `CSS` (the docs page
stylesheet). The rendered OpenAPI document must be valid JSON; the deploy
checks it.

## Environment

`src/types/runtime/templates/env.tmpl` renders the service environment. A
new kind that needs extra variables adds them to that template guarded by an
`{{#IF IS_<KIND>}}` block and sets `IS_<KIND>` in `rt_render_env` in
`src/types/runtime/type.sh`.
