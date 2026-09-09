# getbible/api repository guide

Read this before changing anything. It applies to the whole repository.

## Purpose

`getbible.sh` deploys and maintains every public getBible API domain on a
server: static domains (file trees synced from git repositories and served
by nginx) and runtime domains (the `query` and `search` services built on
the getBible librarian, run by gunicorn behind nginx). Everything the tool
installs is rendered from `src/` and recorded, so `git pull` followed by
`getbible.sh update` brings every domain to the current templates.

## Vocabulary

- A **domain** is a host name: one nginx vhost, one certificate, one go-live.
- An **endpoint** is one of a domain's version folders (`/v2/`): a tree
  synced from its own repository (static) or a service of its own (runtime).
  A domain set up without version folders serves a single endpoint at its
  root, label `root`; domain and endpoint are then the same thing.
- Use these words in the menu, in output and in documentation. The registry
  directory (`/etc/getbible/endpoints/<domain>/endpoint.conf` for the
  domain, `versions/<label>.conf` for its endpoints), the `endpoint_*`
  pipeline functions and the `ep_*` registry functions predate the
  vocabulary and keep their names so installations keep working.

## Layout

- `getbible.sh` - the only entry point: whiptail menu and command line.
- `src/lib/` - bash libraries, sourced by `getbible.sh`, never executed.
- `src/bin/` - helper programs installed to `/usr/local/lib/getbible`.
- `src/nginx/` - nginx templates and snippets.
- `src/types/<type>/` - one domain type each (`static`, `runtime`).
- `src/apps/<kind>/` - runtime applications (`common`, `query`, `search`);
  `src/apps/<kind>-<version>/` an implementation for one version that needs
  its own code. A kind's manifests declare the versions it can serve.
- `src/docs-site/` - templates of the domain pages and the static endpoint
  pages; the runtime kinds carry their own page and OpenAPI templates.
- `tests/` - lint, unit, CLI and integration tests (`tests/run.sh`).
- `docs/` - operator documentation.

## Project policy

The source repositories and sanctioned operators are trusted. Static builders
own content, JSON, schema and checksum validation. This manager copies committed
files faithfully and publishes them atomically; do not add downstream corpus
validation, hash sweeps or approval gates. Runtime endpoints use existing local
data and do not fetch public Bible APIs. Do not add validation passes on top
of the librarian's existing cached data loading.

Availability and fast access are the objective. Preserve open access and the
existing unlimited-token behavior; do not introduce extra quotas, branch
protection, production corpus load tests or monitoring requirements. Cloudflare
management is optional and off by default. When enabled for a domain, only that
domain's owned records and rules may be changed.

Static pages and OpenAPI documents may be supplied freely by the repository or
operator. Generated runtime documentation must match the actual GET query and
POST JSON implementation. Documentation, specifications, discovery and health
remain public regardless of the data access mode.

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
- A staged domain (`LIVE=false`) never takes over its public name on its
  own: no apply requests a certificate or changes Cloudflare DNS or rules
  until go-live, which obtains the certificate before marking it live. The
  operator may issue a certificate for it explicitly (Domain >
  Certificate > Issue; DNS-01 publishes a TXT record) without it going live.
- Anything that changes files on the server sends a Telegram notification
  when Telegram is enabled.
- A page or OpenAPI document an operator has taken over (`custom` source)
  is never rewritten by the tool; generated ones are rewritten on every
  apply. Never hard-code a runtime version: the implementations under
  `src/apps/` declare what they serve.
- Everything is operable from the whiptail menu; a command line form exists
  for every action, and the menu gathers every input before running it.
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
