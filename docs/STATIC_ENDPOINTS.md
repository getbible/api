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

Every **endpoint gets its own ed25519 deploy key** for its repository URL.
For example, `/v1/` and `/v2/` on the same domain can use different GitHub
repositories with different read-only deploy keys. The endpoints share one
domain system user (`gb-sync-<name>`) and nginx vhost. Their keys live under
`/var/lib/getbible/sync/<user>/.ssh/`; private keys have mode `0600`.

After deploying or adding an endpoint, add its displayed public key to that
endpoint's repository as a **read-only deploy key** (GitHub: Settings > Deploy
keys, with Allow write access unchecked; Gitea: Settings > Deploy Keys).
Use the domain's deploy-key menu and choose the endpoint, or run
`getbible.sh deploy-key DOMAIN ENDPOINT`, to show its key again. Register each
key on its own repository; GitHub does not allow one deploy key to be added
to multiple repositories. The repository host's SSH key is pinned in the
sync user's `known_hosts` at deployment.

Each sync and repository-access test selects the endpoint's key explicitly.
SSH configuration files and SSH agents cannot select another identity, and
strict host-key checking stays enabled. Keep the ordinary repository URL:
`git@github.com:owner/repo.git`; no host aliases or URL rewriting are needed.
The SSH user before `@` belongs to the host, not your account. A self-hosted
server with another SSH user or port uses `ssh://user@host:port/path` or
`user@host:path`. Public repositories may use `https://`; private ones need
SSH. Root's key for updating the manager repository is separate.

Domain > Test repository access (or `repo-access DOMAIN ENDPOINT`) checks
the endpoint's currently selected key and reference before the first sync.
Change the repository, branch or folder under Domain > Endpoints > Change
(or `version change`) without losing published releases. A different
repository URL selects a different key: add its public key to the new
repository before syncing. Changing only the branch or source folder keeps
the same key. Keys are retained when changing repositories, so switching
back to the same URL reuses that endpoint's earlier key.

A timer per endpoint (`getbible-sync-<slug>-<label>.timer`, weekly by
default, daily or monthly on request, "Sync now" any time) runs
`/usr/local/lib/getbible/getbible-sync` as that user:

1. `git ls-remote` reads the remote head; unchanged means nothing happens.
2. Telegram: "Update started".
3. Fetch into a persistent shallow Git repository.
4. Export the source folder's committed Git blobs into a new release directory,
   including only the allowed file types plus the page and OpenAPI document
   the endpoint takes from the repository (by path, whatever their type).
   Dotfiles are skipped. Git's existing blob identities identify unchanged
   files, which are **hard-linked from the previous release** so inodes and
   ETags survive; only changed blobs are read and written. No working-tree
   rewrite or full-content comparison is needed.
5. Flip the endpoint's symlink (atomic for the whole tree; nginx keeps
   running). Deletions, including removal of every exported file, follow the
   source repository exactly.
6. Keep the actual current and previous releases, including same-second
   syncs. Older releases have a minimum one-hour cleanup grace period.
7. Telegram: "Update live" with the commit, file count and changed count.
8. As root, outside the sandbox and without affecting the sync's result,
   refresh the domain's generated pages and `versions.json`, so a document
   that arrived with this sync is linked at once.

The repository is the source of truth. JSON, checksum files and manifests
are copied byte for byte without parsing or recalculating their contents.
Their validation belongs to the upstream builders. There is no validation
on requests, and no second pass over the exported corpus. A private export
index records Git blob identities for reuse; it is only an optimization,
and a missing index simply causes the files to be copied on that sync.
A forced sync always copies the committed blobs again, bypassing inode reuse,
so it also restores the repository's exact bytes after local file damage.

Nothing in the export pipeline runs as root and nothing reloads nginx.
Release directories are unique, concurrent runs are locked, and hard-linked
files are never rewritten or have their metadata changed after export.
A fetch, export or publication failure removes only the unpublished
candidate. Responses already streaming keep their open file descriptors across rotation. Multiple
independent HTTP requests can span different releases; the symlink switch is
not a client-wide snapshot transaction.

## Different repositories on one domain

Deploy the domain with its first endpoint, then add other endpoints with
their own repository URLs. Register each endpoint's public key on its
corresponding repository as read-only before testing access and syncing:

```sh
sudo ./getbible.sh deploy static --domain api.getbible.net --version v1 --repo git@github.com:org/bible-v1.git --ref main --staged
sudo ./getbible.sh deploy-key api.getbible.net v1
# Add the displayed public key to org/bible-v1 as a read-only deploy key.
sudo ./getbible.sh repo-access api.getbible.net v1
sudo ./getbible.sh sync api.getbible.net v1

sudo ./getbible.sh version add api.getbible.net v2 --repo git@github.com:org/bible-v2.git --ref main
sudo ./getbible.sh deploy-key api.getbible.net v2
# Add this different public key to org/bible-v2 as a read-only deploy key.
sudo ./getbible.sh repo-access api.getbible.net v2
sudo ./getbible.sh sync api.getbible.net v2
```

The domain's deploy-key menu offers the same show-key, test-access and sync
actions after selecting an endpoint. Showing a key again preserves its
identity, and adding `v2` preserves `v1`'s key and releases. Use `root` as the
endpoint label for a domain without version folders. Once the staged domain
is ready, use the normal go-live workflow to publish its shared hostname.

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
  ETags and Last-Modified support conditional requests (`If-None-Match` or
  `If-Modified-Since`): unchanged files return `304`, changed files return
  `200` with the current representation. Cache policy, validators and CDN
  status headers are readable by cross-origin browser clients. See
  `ACCESS_MODES.md` for lifetimes and stale-response allowances. Gzip and
  optional brotli are supported.
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
getbible.sh deploy-key D v2
getbible.sh repo-access D v2
getbible.sh sync D [v2|root] [--force]
getbible.sh pages D docs v2 repository docs/index.html
getbible.sh pages D openapi v2 repository openapi.json
getbible.sh status D
```
