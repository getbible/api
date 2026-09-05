# Architecture

```
client / Cloudflare
    -> nginx  (TLS, methods, limits, tokens, CORS, problem documents, cache)
        -> static: /srv/getbible/<domain>/<version> -> releases/<version>/<stamp>
        -> runtime: unix socket -> gunicorn -> Flask app -> librarian -> local Bible files
```

## The tool

`getbible.sh` sources `src/lib/*.sh`, then dispatches a command or opens
the menu. The libraries:

| Library | Role |
| --- | --- |
| `core` | paths (all under `GB_PREFIX` for tests), logging, validators, atomic installs, backups, the ledger of installed hashes |
| `ui` | whiptail with plain-prompt and non-interactive fallbacks |
| `config`, `registry` | `KEY=value` files; the endpoint registry under `/etc/getbible/endpoints` |
| `users`, `systemd`, `certs`, `nginx` | system users and groups; units and timers; certbot; render, stage, test, install, reload, drift |
| `access` | access modes, limits, tokens and their nginx snippets |
| `sync` | sync users, deploy keys, sync units |
| `python` | immutable runtime releases |
| `logs`, `analytics`, `telegram`, `cloudflare` | rotation, reports, notifications, Cloudflare |
| `docs`, `endpoint`, `update`, `migrate`, `doctor`, `menu` | documentation pages, the endpoint pipeline, update, legacy migration, host checks, the menu tree |

Endpoint types live in `src/types/<type>/type.sh` and implement
`type_<type>_prepare`, `_render_locations`, `_finish`, `_remove`,
`_status`, `_render_docs`, `_deploy_cli`, `_deploy_interactive`,
`_menu_items` and `_menu_action`. `endpoint_apply` is the one pipeline both
share: prepare, docs, render global and endpoint nginx files, stage, test,
install, certificate (two-phase TLS), finish, Cloudflare, state.

Helper programs in `src/bin/` are installed to `/usr/local/lib/getbible`
for timers and hooks that run as other users: `getbible-sync`,
`getbible-verify-tree`, `getbible-notify`, `getbible-logrotate-hook`. The
rest (`getbible-render`, `getbible-tokens`, `getbible-analytics`,
`getbible-cloudflare`, `getbible-nginx-strip`) run from the checkout.

## nginx layout

- `conf.d/getbible-http.conf`: the JSON log format and the maps that turn
  a bearer token into a caller id and switch the limit key off for it.
- `conf.d/getbible-ep-<slug>.conf`: the endpoint's limit zones and proxy
  cache.
- `snippets/getbible/`: TLS policy, headers, HTML headers, problem
  documents, proxy settings, ACME location.
- `getbible/<domain>/`: `server.conf` (tuning), `limits.conf`, `auth.conf`;
  `getbible/tokens/<slug>.map`.
- `sites-available/<domain>.conf`: the vhost, port 80 with the ACME
  location and a redirect, port 443 with everything above and the type's
  locations.

## State

`/etc/getbible` is configuration, `/var/lib/getbible` is state (ledger,
per-endpoint state, sync homes), `/var/backups/getbible` holds backup sets,
`/var/log/getbible` holds logs. Data roots are `/srv/getbible` (static) and
`/opt/getbible` (runtime releases), with librarian caches under
`/var/cache/getbible/<kind>`.
