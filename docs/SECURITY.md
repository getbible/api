# Security model

Every path, parameter, header and body is untrusted. nginx is the only
process that faces the network; everything behind it is isolated.

## Static domains

- One system user per domain synchronises files with a read-only deploy key
  and a pinned host key; it can write only its own home and data root, runs
  under a hardened oneshot unit, and never touches nginx.
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
- Token map files are root-owned mode 0600 in mode 0700 directories; updates
  also repair unchanged maps from older installations. Token lifetime is
  checked against nginx's current epoch time on every request. An expiry date
  includes that whole UTC day; no timer or reload is required for expiration.
- Token-only data responses use `private, no-store` and bypass nginx caching.
  Cloudflare token-only hosts must bypass caching; transitions purge old
  cached content for that hostname before activation. Missing purge permission
  or a failed purge aborts the protected transition.
- nginx is only ever reloaded after `nginx -t`; every replaced file is
  backed up first; hand edits are detected and never silently overwritten.
- Certificates come from certbot, validated over HTTP-01 in webroot mode or
  over DNS-01 through the Cloudflare token; renewal is certbot's own timer
  with a reload hook; the rendered vhosts are never edited by certbot. For
  DNS-01 the token is handed to certbot in a root-only ini file (0600)
  generated from `cloudflare.conf`.
- A staged domain never requests a certificate or changes DNS on its own
  (an operator may issue its certificate explicitly); it serves a
  self-signed placeholder certificate (root-only key under
  `/etc/getbible/placeholder-certs`) so its vhost can be verified before the
  switch, and the placeholder is deleted when the domain goes live or is
  removed. Go-live obtains the certificate first and leaves the domain
  staged if that fails.
- Rate limits (metered mode) protect the origin from abuse without
  throttling token holders; Cloudflare, when proxied, adds DDoS protection
  and can restrict origin access to its own certificate.
- Runtime Bible data always comes from an existing local repository root;
  upstream checksums are trusted rather than revalidated by the serving process.
- Runtime dependencies are pinned to exact versions; a bump is a reviewed
  commit and an explicit update. CPython distributions have a committed URL,
  exact version, build and SHA-256; their interpreter and standard library do
  not use distro Python paths. Application users cannot write releases or
  interpreters. Host kernel/glibc/nginx security maintenance remains necessary.
- Failed nginx validation or reload restores backed-up files. Runtime
  activation also tracks routing and deployment state for rollback; current
  access mode and tokens are preserved when reverting application settings.

Report vulnerabilities privately to the getBible maintainers.
