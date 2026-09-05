# Cloudflare

Cloudflare blocks API clients when a zone runs with its website defaults:
the browser integrity check, Bot Fight Mode and challenge pages all treat
curl, bots and mobile apps as attackers. The fix is not to turn the proxy
off but to give the API hostnames an API-safe profile, which this tool
applies per domain.

## Token

Settings > Cloudflare API token stores and verifies a scoped token
(`/etc/getbible/cloudflare.conf`, root only). Scopes: Zone:Read, DNS:Edit,
Zone Settings:Edit, Zone WAF:Edit, SSL and Certificates:Edit.

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
  (then origin logs only see cache misses);
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

Everything above works on the Free plan except where Cloudflare restricts a
feature; the tool reports "not applied" with Cloudflare's message and
continues. Rate limiting at the edge is not configured by this tool.
