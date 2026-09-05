# Security model

Every path, parameter, header and body is untrusted. nginx is the only
process that faces the network; everything behind it is isolated.

## Static endpoints

- One system user per domain synchronises files with a read-only deploy key
  and a pinned host key; it can write only its own home and data root, runs
  under a hardened oneshot unit, and never touches nginx.
- Only allowed extensions are exported from a repository and only those are
  served; dotfiles never reach the live root. JSON syntax, available sibling
  checksums and hash manifests are verified before publication. Malformed
  manifests, unsafe paths and symlinks are rejected.
- nginx: no directory listings, no query strings, safe methods only, 1 KB
  body limit, short header and body timeouts, `server_tokens off`, locked
  CSP, `nosniff`, HSTS, JSON problem documents for every error.

## Runtime endpoints

- One system user per kind, no shell, no home; an immutable root-owned
  release; a systemd socket owns the unix socket (0660, nginx's group);
  the service sandbox has no capabilities, read-only file system except its
  cache and log directory, private devices and tmp, no writable-executable
  memory, memory, CPU and task ceilings.
- The application validates versions, translations, references and every
  search parameter before calling the librarian, bounds reference counts,
  verses, query length, page size and offset, and answers with problem
  documents that never contain tracebacks or paths.
- nginx strips the `Authorization` header before proxying and passes only
  the token id; upstream CORS headers are replaced with the endpoint's own.
- Candidate deployments run with their real service identity and must pass
  scripture readiness (plus a search probe for search) before traffic changes.

## Platform

- Secrets (`telegram.conf`, `cloudflare.conf`, `tokens.json`, `runtime.env`)
  are root-only or group-restricted; tokens are 256-bit random and never
  logged; token maps are readable by the nginx master only.
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
- Certificates come from certbot in webroot mode; renewal is certbot's own
  timer with a reload hook; the rendered vhosts are never edited by certbot.
- Rate limits (metered mode) protect the origin from abuse without
  throttling token holders; Cloudflare, when proxied, adds DDoS protection
  and can restrict origin access to its own certificate.
- Runtime dependencies are pinned to exact versions; a bump is a reviewed
  commit and an explicit update. CPython distributions have a committed URL,
  exact version, build and SHA-256; their interpreter and standard library do
  not use distro Python paths. Application users cannot write releases or
  interpreters. Host kernel/glibc/nginx security maintenance remains necessary.
- Failed nginx validation or reload restores backed-up files. Runtime
  activation also tracks routing and deployment state for rollback; current
  access mode and tokens are preserved when reverting application settings.

Report vulnerabilities privately to the getBible maintainers.
