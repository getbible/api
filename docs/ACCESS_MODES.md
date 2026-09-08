# Access modes, tokens and limits

Every domain is in one of three modes that applies to all of its endpoints,
changeable at any time (`getbible.sh access DOMAIN MODE` or the domain menu):

| Mode | Anonymous callers | Token holders |
| --- | --- | --- |
| `open` | unlimited | unlimited |
| `metered` (default) | a budget per client address | unlimited |
| `token` | `401` | unlimited |

## Budgets

Defaults for new domains (Settings > Defaults) and per domain
(`getbible.sh limits DOMAIN --rate N --burst N --hour N --day N --conn N`):

| Setting | Default | Enforced as |
| --- | --- | --- |
| requests per second | 50 | exact rate, `burst` extra requests allowed above it |
| burst | 250 | |
| per hour | 10 000 | token bucket refilling at the hourly rate, capacity a quarter of the quota |
| per day | 100 000 | token bucket refilling at the daily rate, capacity a quarter of the quota |
| concurrent connections | 100 | exact |

A client under its budget is never touched. Over it, nginx answers `429` as
a problem document with `Retry-After`. Budgets key on the client address
(the real one behind Cloudflare, see `CLOUDFLARE.md`); a valid bearer token
switches the key off entirely, which is how token holders are exempt.

## Tokens

Tokens are random 256-bit values rendered as lowercase base32 (`gb...`, 54
characters). They live in `/etc/getbible/endpoints/<domain>/tokens.json`
(root only) with an id, a label, created, optional expiry and revoked
timestamps. nginx gets a rendered map, `getbible/tokens/<slug>.map`, keyed
by `"<domain> Bearer <token>"`, so a token is valid only on the domain
that issued it and its id (never the secret) appears in logs and analytics.

Both the token store and generated secret maps have root-only mode 0600;
map directories have mode 0700. Expiry is evaluated on every request against
nginx's current epoch time, independent of the server timezone or reload
schedule. `--expires 2027-01-01` remains valid through that UTC date and expires
at 00:00 UTC on January 2. Expiration also removes the metered-mode exemption.
Revocation updates the generated maps through the normal domain apply.

Token-only data responses use `Cache-Control: private, no-store`; nginx and
Cloudflare shared caches are bypassed. When a proxied domain becomes
token-only, previously cached content is purged for that host before origin
activation. This needs Cloudflare Cache Purge permission. Open/metered
domains retain their configured public caching behavior.

```sh
getbible.sh token DOMAIN add "Mobile app"            # prints the token once
getbible.sh token DOMAIN add "Partner" --expires 2027-01-01
getbible.sh token DOMAIN list
getbible.sh token DOMAIN revoke tk_1a2b3c4d
```

Clients send `Authorization: Bearer <token>`. Tokens are never accepted in
the URL. CORS preflights, the documentation pages, the OpenAPI documents,
`versions.json`, the favicon and the health routes are always open, so
browsers can reach the `401`.
