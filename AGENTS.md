# getbible/api repository guide

Read this before changing anything. It applies to the whole repository.

## Purpose

`getbible.sh` deploys and maintains every public getBible API domain on a
server: static domains (file trees synced from git repositories and served
by nginx) and runtime domains (the `query` and `search` services built on
the getBible librarian, run by gunicorn behind nginx). Everything the tool
installs is rendered from `src/` and recorded. Native `getbible.sh self-update`
fetches the tracked upstream into the manager's source checkout only;
the next invocation loads the new code. Separately, `getbible.sh update`
applies the current checkout to hosted domains without fetching.
Docker installations load the manager from the image and use image replacement
for manager updates; `getbible` is a command linked to the same entry point.
See `docs/DEPLOYMENT_DECISIONS.md` before changing deployment behavior.

## Vocabulary

- A **domain** is a host name: one nginx vhost, one go-live, and a certificate
  at the TLS terminator (local nginx with managed TLS, external HAProxy with
  external TLS).
- An **endpoint** is one of a domain's version folders (`/v2/`): a tree
  synced from its own repository with its own deploy key (static) or a
  service of its own (runtime). Static deploy keys belong to endpoints,
  never to a domain: endpoints on one domain may use different repositories.
  A domain set up without version folders serves a single endpoint at its
  root, label `root`; that endpoint still owns its repository identity while
  the domain owns the hostname and TLS configuration.
- Use these words in the menu, in output and in documentation. The registry
  directory (`/etc/getbible/endpoints/<domain>/endpoint.conf` for the
  domain, `versions/<label>.conf` for its endpoints), the `endpoint_*`
  pipeline functions and the `ep_*` registry functions use these paths and
  names consistently.

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
- `img/` - the getBible icons every domain serves by default (favicon, page
  logo, touch icon, link-preview image); `pages.sh` publishes them.
- `tests/` - lint, unit, CLI and integration tests (`tests/run.sh`).
- `docs/` - operator documentation.

## Project policy

Operator-provided deployment information is private. Never copy an operator's
hardware inventory, co-hosted services, private addresses, hostnames or local
infrastructure details into source, tests, documentation, examples, commit
messages, pull requests or release notes. Use generic examples and synthetic
test data. Keep deployment-specific configuration outside version control.

The source repositories and sanctioned operators are trusted. Static builders
own content, JSON, schema and checksum validation. This manager copies committed
files faithfully and publishes them atomically; do not add downstream corpus
validation, hash sweeps or approval gates. Runtime endpoints use existing local
data and do not fetch public Bible APIs. Do not add validation passes on top
of the librarian's existing cached data loading.

Availability and fast access are the objective. Preserve open access and the
existing unlimited-token behavior; do not introduce extra quotas, branch
protection, production corpus load tests or monitoring requirements. Cloudflare
management is optional and off by default for native deployment. The supplied
Docker external-proxy profile uses proxied Cloudflare with Free capabilities
and public cache respect mode. Public edge cache hits are desirable and need
not count toward origin analytics or public budgets: limits protect origin
capacity. Preserve token-only cache bypass and public-to-private purge behavior.
Paid features require explicit selection and actual zone entitlement. When
Cloudflare is enabled for a domain, only that domain's owned records and rules
may be changed; do not silently change zone-wide settings for unrelated sites.

Static pages and OpenAPI documents may be supplied freely by the repository or
operator. Generated runtime documentation must match the actual GET query and
POST JSON implementation. Documentation, specifications, discovery and health
remain public regardless of the data access mode.

## Rules

- Support fresh installations and ongoing maintenance of this implementation.
  Preserve normal updates, redeployment, certificate renewal and generation
  rollback. Do not add conversion of old schemas, legacy filesystem layouts
  or retirement routines for a previous server implementation.

- Preserve both native and Docker execution modes. Docker is one Linux system
  container with systemd, nginx and managed services; keep service identities,
  sandboxes, timers, socket/readiness/drain and rollback behavior. Do not turn
  test path redirection into container detection. TLS ownership is independent
  of execution mode; external TLS serves complete HTTP vhosts behind trusted
  proxies and retains public HTTPS URLs.
- Container startup restores saved local state, identities and enabled services
  before traffic. It must not fetch updates, redeploy applications, issue
  certificates or take over DNS as a side effect of an ordinary restart.
  Persist account UIDs/GIDs and membership before services access mounted data;
  do not blanket-chown a corpus to hide an identity collision.
- Release images contain the dependencies offered by Docker's runtime menu;
  endpoint deployment must not download Python or compile runtime packages.
  Container manager updates come from the image, native manager updates from
  Git. Keep explicit endpoint apply/update and retained-generation rollback.
- Environment overrides must be validated and identified as authoritative in
  the manager. Aggregate memory budgeting must account for all runtime endpoints
  and update overlap; never promise fixed cache-entry counts are byte limits.

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
- Static domains share one sync system user and one nginx vhost, while each
  endpoint has a separate SSH deploy key for its repository URL. Select the
  key explicitly for every sync and access test; keep ordinary repository
  hostnames, ignore ambient SSH configuration and agents, and preserve strict
  host-key checking. A repository URL change selects a different key; changing
  only its branch or source folder preserves the key. Root's key for updating
  this manager is separate from every endpoint key.
- nginx is only ever reloaded, never restarted, and only after `nginx -t`.
- A staged domain (`LIVE=false`) never takes over its public name on its
  own: no apply requests a certificate or changes Cloudflare DNS or rules
  until go-live. Managed TLS obtains the local certificate before activation;
  external TLS checks the local HTTP origin first and verifies public HTTPS
  after activation, with certificate provisioning owned by the proxy. The
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
  integration tests need nginx, openssh-server and root. Run tests locally
  before pushing changes; deployment changes also need the disposable Ubuntu
  systemd acceptance test below.

## Adding a runtime kind

See `docs/ADDING_A_RUNTIME_KIND.md`. A kind is a directory under
`src/apps/` with `manifest.conf`, a Python package, pinned requirements,
an OpenAPI document, a documentation template and tests; a test fails when
any of these is missing.

## Verification

```sh
tests/run.sh            # lint + unit + CLI
tests/run.sh --all      # plus nginx, runtime and SSH integration (runs as root)
# Only on a fresh disposable Ubuntu VM, after install-deps:
sudo env GB_CI_DISPOSABLE_HOST=1 tests/integration/systemd.sh
```
