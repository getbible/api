# Static endpoints

A static endpoint is a domain serving one or more **versions**, each a tree of
files synchronised from a git repository and served by nginx exactly as
published. The tool never writes into a version's files; it only decides
which files are copied out of the repository and how they are served.

## Versions

Each version is its own record: label (`v1`, `v2`, ...), repository, branch
or tag, and the folder inside the repository that holds the tree (`.` when
the repository root is the version, `v1` when the repository keeps a version
folder). Versions are served under their label:

```
https://api.getbible.net/v2/kjv/1/1.json   ->   /srv/getbible/api.getbible.net/v2/kjv/1/1.json
```

`/srv/getbible/<domain>/<version>` is a symlink to the current release under
`releases/<version>/`. Add or retire versions from the endpoint's menu
(Manage versions) or with `getbible.sh version add|remove`.

## Synchronisation

Every domain gets its own system user (`gb-sync-<name>`) with an ed25519
deploy key under `/var/lib/getbible/sync/<user>/.ssh/`. Add the public key
(shown after deployment, or Endpoint > Show the deploy key) to the repository
as a read-only deploy key on GitHub or Gitea. The repository host's SSH key is
pinned in the user's `known_hosts` at deployment.

A timer per version (`getbible-sync-<slug>-<version>.timer`, weekly by
default, daily or monthly on request, "Sync now" any time) runs
`/usr/local/lib/getbible/getbible-sync` as that user:

1. `git ls-remote` reads the remote head; unchanged means nothing happens.
2. Telegram: "Update started".
3. Fetch into a persistent shallow checkout.
4. Export the source folder into a new release directory with rsync, copying
   only the allowed file types, skipping dotfiles, and **hard-linking every
   unchanged file from the previous release** so inodes and ETags survive.
5. Verify: every `.sha` next to a `.json` must hold that file's SHA-1; every
   `hashes.json` manifest must describe existing files with matching
   digests. A failure deletes the export and leaves the old release live.
6. Flip the version symlink (atomic for the whole tree; nginx keeps running).
7. Keep the previous release for rollback, delete older ones.
8. Telegram: "Update live" with the commit, file count and changed count.

Nothing in this pipeline runs as root and nothing reloads nginx.

## Serving

- Only the allowed extensions are served (`json`, `sha`, `txt` by default,
  `html` on request); anything else, dotfiles and directories answer a JSON
  404. Query strings answer 400: nothing here takes parameters.
- `GET`, `HEAD`, `OPTIONS` only; `OPTIONS` answers 204 with the CORS headers.
- CORS is open on every response. Security headers: `nosniff`, a locked CSP,
  `no-referrer`, `Cross-Origin-Resource-Policy: cross-origin`, HSTS.
- `Cache-Control: public, max-age=3600` (documents) and `300` (checksums),
  both with stale-while-revalidate; ETags on everything; gzip and brotli.
- The domain root serves the documentation page; `/healthz` answers for
  monitors. A version's own `openapi.json`, when the repository ships one,
  is linked from that page.

## Access

Access mode, limits and tokens are per endpoint; see `ACCESS_MODES.md`.

## Commands

```sh
getbible.sh deploy static --domain D --version v2 --repo git@github.com:org/repo.git [--ref master] [--path .] [--extensions json,sha,txt] [--access metered] [--schedule weekly]
getbible.sh version add D v1 --repo URL [--ref main] [--path v1]
getbible.sh version remove D v1
getbible.sh sync D [v2] [--force]
getbible.sh status D
```
