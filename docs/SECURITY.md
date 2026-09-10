# Security model

Every request path, parameter, header and body is untrusted. nginx is the
application's network-facing process; its runtime services use Unix sockets.
Native managed TLS terminates there. The Docker external-TLS profile places
Cloudflare and OPNsense HAProxy in front of nginx.

## Container and proxy boundaries

Docker mode retains systemd and the existing per-service users, restricted
write paths and service hardening. The root management process needs authority
to create users and units. Running systemd's nested mount namespaces also
requires the explicitly documented system-container permissions in
[DOCKER.md](DOCKER.md); this is a trusted system image, not an unprivileged
single-process container. Do not mount the Docker socket or host account files
inside it. The container uses its own cgroup namespace, not writable access to
the host's complete cgroup hierarchy.

Persistent accounts are restored from recorded numeric UIDs/GIDs and group
membership before mounted services start. Account collisions stop restoration
for correction rather than changing corpus ownership. Configuration, SSH keys,
token stores and backups under the host data parent retain their restricted
permissions. Give host access to that parent only to authorized operators.

HAProxy preserves the requested hostname and bearer authorization. It accepts
Cloudflare client identity only from verified Cloudflare peers, then replaces
forwarding headers with normalized values. nginx trusts only the specified
HAProxy source addresses and creates the runtime token-ID header itself.
The raw bearer secret never reaches the application or request logs. See
[OPNSENSE_HAPROXY.md](OPNSENSE_HAPROXY.md) for exact responsibilities and tests.

External TLS does not request local certificates. Cloudflare Full (strict)
validates HAProxy's domain certificate; optional Authenticated Origin Pulls
verification belongs on HAProxy. Restrict the plaintext origin port to the
intended LAN proxy/operator paths. Public open/metered edge caching is
deliberate; authorization-bearing requests bypass the edge cache, and
token-only data bypasses shared caches at both layers.

The GHCR pull credential belongs on the Docker host. It is separate from
Cloudflare credentials and each endpoint's SSH deploy key, and is not needed
inside the container. Native manager Git keys retain their existing purpose;
the image's manager code is updated by replacing the image.

## Static domains

- Each static endpoint has its own read-only deploy key for its repository
  URL, selected explicitly for syncs and access tests. SSH agents and ambient
  SSH configuration are disabled; pinned host keys and strict host checking
  remain enabled. Changing repositories selects a different key; changing
  only a branch or source folder preserves it. Private keys have mode `0600`.
- One system user per domain synchronises its endpoints. The domain is the
  operating-system isolation boundary: its endpoints share that user's home
  and data permissions, while their repository identities are separate. The
  user can write only its own home and data root, runs under a hardened
  oneshot unit, and never touches nginx. Root's manager-update key is separate.
- Only allowed extensions are exported from a repository and only those are
  served, plus the page and OpenAPI document an endpoint takes from the
  repository by explicit path (no dot segments, never a symlink); dotfiles
  never reach the live root. Committed repository bytes are authoritative:
  builders validate JSON, checksums and manifests upstream. Publication uses
  Git object identity to reuse unchanged files without rereading their bodies;
  unsafe paths, symlinks and interrupted transfers are still rejected.
- nginx: no directory listings, no query strings, safe methods only, 1 KB
  body limit, short header and body timeouts, `server_tokens off`, locked
  CSP, `nosniff`, HSTS, JSON problem documents for every error.

## Runtime domains

- One system user per kind, no shell, no home; one service per endpoint, each
  an immutable root-owned release; a systemd socket owns the unix socket
  (0660, nginx's group);
  the service sandbox has no capabilities, read-only file system except its
  cache and log directory, private devices and tmp, no writable-executable
  memory, memory, CPU and task ceilings.
- The application validates versions, translations, references and every
  search parameter before calling the librarian, bounds reference counts,
  verses, query length, page size and offset, and answers with problem
  documents that never contain tracebacks or paths.
- nginx strips the `Authorization` header before proxying and passes only
  the token id; upstream CORS headers are replaced with the domain's own.
  For a domain that serves its endpoint at the root, nginx adds the version
  segment and strips it from redirects; the internal prefix it uses for the
  page's hand-over is marked `internal` and answers 404 to clients.
- Candidate deployments run with their real service identity and must pass
  scripture readiness (plus a search probe for search) before traffic changes.

## Platform

- Secrets (`telegram.conf`, `cloudflare.conf`, `tokens.json`,
  `runtime-<label>.env`) are root-only or group-restricted; tokens are
  256-bit random and never logged; token maps are readable by the nginx
  master only.
- Pages, OpenAPI documents, the favicon and `versions.json` are served by
  exact nginx locations with fixed media types and the HTML or API security
  headers; a page an operator takes over lives under `/var/www/getbible/`,
  root-owned, and is never rewritten by the tool. The sync units' post-run
  refresh of generated files runs as root outside the sync sandbox and only
  writes generated files under that directory.
- Token map files are root-owned mode 0600 in mode 0700 directories. Token lifetime is
  checked against nginx's current epoch time on every request. An expiry date
  includes that whole UTC day; no timer or reload is required for expiration.
- Token-only data responses use `private, no-store` and bypass nginx caching.
  Cloudflare token-only hosts must bypass caching; transitions purge old
  cached content for that hostname before activation. Missing purge permission
  or a failed purge aborts the protected transition.
- nginx is only ever reloaded after `nginx -t`; every replaced file is
  backed up first; hand edits are detected and never silently overwritten.
- In managed TLS mode, certificates come from certbot, validated over HTTP-01 in webroot mode or
  over DNS-01 through the Cloudflare token; renewal is certbot's own timer
  with a reload hook; the rendered vhosts are never edited by certbot. For
  DNS-01 the token is handed to certbot in a root-only ini file (0600)
  generated from `cloudflare.conf`.
- A staged domain never requests a certificate or changes DNS on its own
  (an operator may issue its certificate explicitly); it serves a
  self-signed placeholder certificate in managed TLS mode (root-only key under
  `/etc/getbible/placeholder-certs`) so its vhost can be verified before the
  switch, and the placeholder is deleted when the domain goes live or is
  removed. Go-live obtains the certificate first and leaves the domain
  staged if that fails.
- Rate limits (metered mode) protect the origin from abuse without
  throttling token holders; Cloudflare, when proxied, adds DDoS protection
  and can restrict origin access to its own certificate.
- Runtime Bible data always comes from an existing local repository root;
  the manager adds no corpus validation pass. Checksum files are optional;
  the librarian can still use supplied hashes during its cached data loading.
- Runtime dependencies are pinned to exact versions; a bump is a reviewed
  commit and an explicit update. CPython distributions have a committed URL,
  exact version, build and SHA-256; their interpreter and standard library do
  not use distro Python paths. Application users cannot write releases or
  interpreters. Host kernel/glibc/nginx security maintenance remains necessary.
- Failed nginx validation or reload restores backed-up files. Runtime
  activation also tracks routing and deployment state for rollback; current
  access mode and tokens are preserved when reverting application settings.

Report vulnerabilities privately to the getBible maintainers.
