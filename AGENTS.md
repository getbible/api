# getbible/api repository guide

Read this before changing anything. It applies to the whole repository.

## Purpose

`getbible.sh` deploys and maintains every public getBible API endpoint on a
server: static endpoints (versioned file trees synced from git repositories
and served by nginx) and runtime endpoints (the `query` and `search`
services built on the getBible librarian, run by gunicorn behind nginx).
Everything the tool installs is rendered from `src/` and recorded, so
`git pull` followed by `getbible.sh update` brings every endpoint to the
current templates.

## Layout

- `getbible.sh` - the only entry point: whiptail menu and command line.
- `src/lib/` - bash libraries, sourced by `getbible.sh`, never executed.
- `src/bin/` - helper programs installed to `/usr/local/lib/getbible`.
- `src/nginx/` - nginx templates and snippets.
- `src/types/<type>/` - one endpoint type each (`static`, `runtime`).
- `src/apps/<kind>/` - runtime applications (`common`, `query`, `search`).
- `src/docs-site/` - documentation page templates served at domain roots.
- `tests/` - lint, unit, CLI and integration tests (`tests/run.sh`).
- `docs/` - operator documentation.

## Rules

- Commits are authored in the maintainer's name. Do not add a
  `Co-Authored-By` trailer, a session link, an assistant name, or any other
  tool attribution to a commit message, tag, or pull request.
- The librarian (`getbible` on PyPI) is a dependency: use its public API,
  never re-implement or wrap around its behaviour. If it lacks something,
  extend the librarian instead.
- Runtime endpoints are strictly separate: `query` serves references only,
  `search` serves searches (and resolves a reference typed as a search).
  Neither exposes the other's routes.
- Every error is an RFC 9457 problem document (`application/problem+json`).
- nginx is only ever reloaded, never restarted, and only after `nginx -t`.
- A staged endpoint (`LIVE=false`) never takes over its public name on its
  own: no apply requests a certificate or changes Cloudflare DNS or rules
  until go-live, which obtains the certificate before marking it live. The
  operator may issue a certificate for it explicitly (Endpoint >
  Certificate > Issue; DNS-01 publishes a TXT record) without it going live.
- Anything that changes files on the server sends a Telegram notification
  when Telegram is enabled.
- Never log a bearer token. Everything else about a request is logged.
- Keep `tests/run.sh` green: shellcheck, Python unit tests, CLI tests. The
  integration tests need nginx and are run when it is present.

## Adding a runtime kind

See `docs/ADDING_A_RUNTIME_KIND.md`. A kind is a directory under
`src/apps/` with `manifest.conf`, a Python package, pinned requirements,
an OpenAPI document, a documentation template and tests; a test fails when
any of these is missing.

## Verification

```sh
tests/run.sh            # lint + unit + CLI
tests/run.sh --all      # plus integration (needs nginx, runs as root)
```
