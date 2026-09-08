# Cloudflare

Cloudflare blocks API clients when a zone runs with its website defaults:
the browser integrity check, Bot Fight Mode and challenge pages all treat
curl, bots and mobile apps as attackers. The fix is not to turn the proxy
off but to give the API hostnames an API-safe profile, which this tool
applies per domain.

## Token

Settings > Cloudflare API token stores and verifies a scoped token
(`/etc/getbible/cloudflare.conf`, root only). Scopes: Zone:Read, DNS:Edit,
Zone Settings:Edit, Zone WAF:Edit, SSL and Certificates:Edit, and Cache
Purge:Purge for protected endpoint transitions. Limit the token to the zones
managed by this installation. DNS:Edit also serves certificate validation
(below).

## Certificates before DNS changes (DNS-01)

With the `certbot-dns-cloudflare` plugin installed (`install-deps` adds
`python3-certbot-dns-cloudflare`), certbot proves control of a name by
publishing a `_acme-challenge` TXT record through the stored token instead of
answering an HTTP request. The certificate can therefore be issued while the
name still points at another server: on a staged endpoint (Endpoint >
Certificate > Issue) or during go-live, before the records are switched.
Settings > Certificate validation chooses `auto` (DNS-01 for a domain whose
mode is `dns` or `proxied` whenever the plugin and token are present,
otherwise HTTP-01, since the token cannot be assumed to cover other zones),
`http` or `dns-cloudflare`; Go live and Issue can choose per request. certbot
keeps a root-only copy of the token in `/etc/getbible/certbot-cloudflare.ini`
for renewals; storing a token writes it, and the host check warns about
DNS-01 renewals that lack it.

## Staged endpoints

A staged endpoint (deployed with "Stage it", see `NEW_SERVER.md`) records
its Cloudflare mode, cache and origin-pull settings but applies none of them:
the DNS records keep pointing at whatever serves the name today, and the
origin-side real-IP and origin-pull settings are left out of its nginx vhost
so it can be verified directly. Go live requires the token for such a
domain, fetches the address ranges and origin CA before rendering the live
vhost, and applies DNS and rules after the certificate exists. For a proxied
domain, HTTP-01 validation at go-live is refused unless the name already
reaches this server, because the records are switched only afterwards; use
DNS-01.

## Per domain

Endpoint > Cloudflare settings, or `getbible.sh cloudflare mode DOMAIN off|dns|proxied`:

| Mode | Effect |
| --- | --- |
| `off` | not managed |
| `dns` | the A/AAAA records are created or updated, grey cloud: traffic reaches the origin directly |
| `proxied` | orange cloud, plus the API profile below |

The API profile for a proxied host, applied as rules that only match that
hostname so the rest of the zone is untouched:

- configuration rule: browser integrity check off, security level
  "essentially off", SSL strict;
- cache rule: `bypass` (default) so every request reaches the origin and its
  logs stay complete, or `respect` to cache per the origin's `Cache-Control`
  (then origin logs only see cache misses). `respect` is available for
  open/metered endpoints; token-only endpoints always bypass caching;
- WAF custom rule skipping managed challenges and Cloudflare rate limiting
  for the host (DDoS protection stays on).

Origin side, for proxied hosts:

- `real_ip` restoration from Cloudflare's published ranges, refreshed daily
  by `getbible-cloudflare-ips.timer`, so budgets and unique-caller counts see
  real clients;
- optional authenticated origin pulls: the origin verifies Cloudflare's
  client certificate and nobody else can talk to it directly.

Zone-wide toggles that cannot be scoped to a host (Bot Fight Mode off;
HTTP/3, brotli, TLS 1.2 minimum, always HTTPS) are under System > Cloudflare
origin tools and applied only on explicit request.

## Plans

Feature availability and API permissions depend on the account and plan.
Optional WAF/zone settings can report "not applied" with Cloudflare's message.
Security-critical cache protection does not silently continue: before a
token-only transition, the manager installs a host-specific bypass rule and
purges that hostname's cached content. A rejected purge or missing credentials
aborts activation. It never falls back to purging the entire zone.

If a protected transition fails, correct the token's Cache Purge permission
and retry `sudo ./getbible.sh apply api.getbible.net`. Existing public data
cannot be recalled from clients that already downloaded it. Review any
independently managed CDN rules that could override the host's cache policy.
Rate limiting at the edge is not configured by this tool.
