# Static domains and their endpoints

A static domain serves one or more **endpoints**, each a tree of files
synchronised from a git repository and served by nginx exactly as published.
The tool never writes into an endpoint's files; it only decides which files
are copied out of the repository and how they are served.

## Endpoints

An endpoint is a version folder of the domain: `/v1/`, `/v2/`, each its own
record (label, repository, branch or tag, and the folder inside the
repository that holds the tree: `.` when the repository root is the tree,
`v1` when the repository keeps a version folder). Endpoints are served under
their label:

```
https://api.getbible.net/v2/kjv/1/1.json   ->   /srv/getbible/api.getbible.net/v2/kjv/1/1.json
```

`/srv/getbible/<domain>/<label>` is a symlink to the current release under
`releases/<label>/`. Add, change or retire endpoints from the domain's menu
(Endpoints) or with `getbible.sh version add|change|remove`.

A domain may instead serve a single endpoint at its **root**: leave the
version folder empty in the deploy walkthrough (`--version root` on the
command line). Its tree is served at `/`
(`https://files.getbible.net/kjv/1/1.json`), its page at `/` and its OpenAPI
document at `/openapi.json`; the record and the release directory carry the
label `root`. Such a domain cannot add version folders later, and a domain
with version folders cannot add a root endpoint: remove the one to switch to
the other.

Every endpoint has a documentation page at `/vN/` and may have an OpenAPI
document at `/vN/openapi.json`; the domain page at `/` lists the endpoints
and `/versions.json` maps them to their documents. See [PAGES.md](PAGES.md)
for where these come from and how to take them over.

## Synchronisation

Every domain gets its own system user (`gb-sync-<name>`) with an ed25519
deploy key under `/var/lib/getbible/sync/<user>/.ssh/`. Add the public key
(shown after deployment, or Domain > Show the deploy key) to the repository
as a read-only deploy key on GitHub or Gitea. The repository host's SSH key is
pinned in the user's `known_hosts` at deployment.

There is no account name or password anywhere: the deploy key is the whole
identity, and git runs as the sync user with that key only. The SSH user in
the repository URL is the host's, not yours: `git@github.com:owner/repo.git`
on GitHub, GitLab and Gitea (they accept nothing but `git`). A self-hosted
server with another SSH user or port is written `ssh://user@host:port/path`
or `user@host:path`. Public repositories may use `https://`; private ones
need SSH. Domain > Test repository access proves the key and URL work
before the first sync. An endpoint's repository, branch or folder can be
changed later under Domain > Endpoints > Change (or `version change`)
without losing its releases; the next sync publishes from the new source.

A timer per endpoint (`getbible-sync-<slug>-<label>.timer`, weekly by
default, daily or monthly on request, "Sync now" any time) runs
`/usr/local/lib/getbible/getbible-sync` as that user:

1. `git ls-remote` reads the remote head; unchanged means nothing happens.
2. Telegram: "Update started".
3. Fetch into a persistent shallow checkout.
4. Export the source folder into a new release directory with rsync, copying
   only the allowed file types plus the page and OpenAPI document the
   endpoint takes from the repository (by path, whatever their type),
   skipping dotfiles, and **hard-linking every unchanged file from the
   previous release** so inodes and ETags survive.
5. Verify every JSON document; every `.sha` must have a JSON sibling and hold
   that file's SHA-1; every
   `hashes.json` manifest must describe existing files with matching
   digests. A failure deletes the export and leaves the old release live.
6. Flip the endpoint's symlink (atomic for the whole tree; nginx keeps
   running).
7. Keep the actual current and previous releases, including same-second
   syncs. Older releases have a minimum one-hour cleanup grace period.
8. Telegram: "Update live" with the commit, file count and changed count.
9. As root, outside the sandbox and without affecting the sync's result,
   refresh the domain's generated pages and `versions.json`, so a document
   that arrived with this sync is linked at once.

Nothing in the export pipeline runs as root and nothing reloads nginx.
Release directories are unique, concurrent runs are locked, and hard-linked
files are never rewritten or have their metadata changed after export.
Verification failure removes only the unpublished candidate. Responses
already streaming keep their open file descriptors across rotation. Multiple
independent HTTP requests can span different releases; the symlink switch is
not a client-wide snapshot transaction.

## Serving

- Only the allowed extensions are served (`json`, `sha`, `txt` by default,
  `html` on request); anything else, dotfiles and directories answer a JSON
  404. Query strings answer 400: nothing here takes parameters.
- `GET`, `HEAD`, `OPTIONS` only; `OPTIONS` answers 204 with the CORS headers.
- CORS is open on every response. Security headers: `nosniff`, a locked CSP,
  `no-referrer`, `Cross-Origin-Resource-Policy: cross-origin`, HSTS.
- `Cache-Control: public, max-age=3600` (documents) and `300` (checksums),
  both with stale-while-revalidate in open/metered mode. Token-only documents,
  checksums and HTML use `private, no-store` with `Vary: Authorization`.
  ETags and conditional requests remain available; gzip and optional brotli.
- The domain page, the endpoint pages, the OpenAPI documents, `versions.json`
  and the favicon are public in every access mode, served by exact locations
  independent of the allowed file types; `/vN` redirects to `/vN/`;
  `/healthz` answers for monitors.

## Access

Access mode, limits and tokens are per domain and apply to every endpoint;
see `ACCESS_MODES.md`.

## Commands

```sh
getbible.sh deploy static --domain D --version v2 --repo git@github.com:org/repo.git [--ref master] [--path .] [--extensions json,sha,txt] [--access metered] [--schedule weekly]
getbible.sh deploy static --domain D --version root --repo git@github.com:org/repo.git   # the tree at https://D/
getbible.sh version change D v2 [--repo URL] [--ref REF] [--path P]
getbible.sh version add D v1 --repo URL [--ref main] [--path v1]
getbible.sh version remove D v1
getbible.sh sync D [v2|root] [--force]
getbible.sh pages D docs v2 repository docs/index.html
getbible.sh pages D openapi v2 repository openapi.json
getbible.sh status D
```
