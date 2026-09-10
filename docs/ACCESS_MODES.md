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

## Response caching for browsers and API clients

Every domain advertises its cache policy in HTTP response headers, whether
Cloudflare proxying is enabled or callers connect directly. `Cache-Control`
tells a browser, application cache or CDN how long it may reuse a response;
it cannot force a caller to maintain a cache. Current defaults are:

| Public resource or response | Fresh lifetime (`max-age`) |
| --- | --- |
| Static JSON and text data | 3,600 seconds |
| Static `.sha` change tokens | 300 seconds |
| Query GET/HEAD data | 300 seconds |
| Search GET/HEAD data, including query-string filters | 60 seconds |
| Documentation, OpenAPI and version discovery | 300 seconds |
| Favicon and page images | 86,400 seconds |
| nginx-generated not-found responses | 60 seconds |

Static HTML data uses the 300-second documentation lifetime. Configured
domain/endpoint lifetimes replace these defaults. Public static data also
allows stale responses for 86,400 seconds while revalidating or during an
origin error; `.sha` allows 3,600 seconds while revalidating and 86,400 during
an error. Query/search responses allow 60 seconds while revalidating.
These stale allowances favor availability and are additional to the fresh
lifetime. nginx may also serve its existing public runtime cache during an
upstream error or refresh.

Cache the URL including its entire query string: different search filters
must have separate entries. Retain the returned `ETag`, then send it as
`If-None-Match` when revalidating. An unchanged representation returns `304`
with no response body and its cache policy; reuse the stored body. Changed
content returns `200` with its new body and ETag. Static files also provide
`Last-Modified` and accept `If-Modified-Since`. An ETag represents the exact
response; `.sha` files and search `query.sha` identify the underlying data.
Response freshness still follows its cache lifetime, so token changes do
not instantly invalidate copies already held by callers.

For V2 consumers that persist scripture, HTTP freshness does not replace the
[V2 scripture-cache policy](https://github.com/getbible/mcp/blob/main/site/v2/cache-policy.md).
Store each payload with its exact translation/book/chapter scope hash and
last successful check time; recheck at least weekly. Invalidate the changed
scope and its cached descendants, then atomically replace the payload and
hash. Grouped query results need every participating chapter hash. If a
check fails, do not advance the check time or claim that the text is current.
These hashes are opaque change tokens, not publisher identity or a
cryptographic trust mechanism. This is a consumer caching contract; the
deployment manager continues publishing the builder's files faithfully.

nginx revalidates expired public runtime cache entries with the application's
ETag. Revalidation still executes the runtime request to establish whether
its representation changed; it saves response transfer, not that work.
Conditional static requests avoid transferring unchanged files.

Search POST responses, health/readiness, runtime problem responses and nginx
errors other than generic not-found are `no-store`. Token-only data is
`private, no-store` and bypasses shared caches; conditional requests must
still pass authentication. Public documentation remains cacheable in every
access mode. Access tokens on open/metered domains do not make the public
Bible data private.

Cross-origin browser code can read `Cache-Control`, `ETag`, `Last-Modified`,
`Date`, `Age`, `Expires`, `Retry-After` and the available cache status headers.
`X-Cache-Status` describes nginx runtime caching; `CF-Cache-Status` and `Age`
can describe Cloudflare caching when enabled. Headers are exposed when
present, not synthesized when that cache is absent. See `CLOUDFLARE.md` for
the optional domain-scoped proxy and cache setup.
