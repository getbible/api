# Cloudflare

Direct traffic is the default. New domains use `off`: the tool does not
manage Cloudflare DNS or enable its proxy. A stored Cloudflare token does
not change this choice. Select `dns` on an individual domain if Cloudflare
should manage its A/AAAA records while clients connect directly to the
server. Select `proxied` explicitly only for domains that should use the
Cloudflare proxy.

For a proxied domain, the tool applies an API-friendly profile so browser
challenges and Cloudflare rate limiting do not obstruct API clients.
The existing origin access modes and unlimited access for valid tokens
are unchanged.

## Token

Settings > Cloudflare API token stores and verifies a scoped token
(`/etc/getbible/cloudflare.conf`, root only). Scopes: Zone:Read, DNS:Edit,
Zone Settings:Edit, Zone WAF:Edit, SSL and Certificates:Edit, and Cache
Purge:Purge for protected domain transitions. Limit the token to the zones
managed by this installation. DNS:Edit also serves certificate validation
(below).

## Certificates before DNS changes (DNS-01)

With the `certbot-dns-cloudflare` plugin installed (`install-deps` adds
`python3-certbot-dns-cloudflare`), certbot proves control of a name by
publishing a `_acme-challenge` TXT record through the stored token instead of
answering an HTTP request. The certificate can therefore be issued while the
name still points at another server: on a staged domain (Domain >
Certificate > Issue) or during go-live, before the records are switched.
Settings > Certificate validation chooses `auto` (DNS-01 for a domain whose
mode is `dns` or `proxied` whenever the plugin and token are present,
otherwise HTTP-01, since the token cannot be assumed to cover other zones),
`http` or `dns-cloudflare`; Go live and Issue can choose per request. certbot
keeps a root-only copy of the token in `/etc/getbible/certbot-cloudflare.ini`
for renewals; storing a token writes it, and the host check warns about
DNS-01 renewals that lack it.

## Staged domains

A staged domain (deployed with "Stage it", see `NEW_SERVER.md`) records
its Cloudflare mode and cache setting but applies neither: the DNS records
keep pointing at whatever serves the name today. The origin-side real-IP
and origin-pull directives are rendered whenever the mode is `proxied` and
the files they need exist; on a freshly built server they do not exist
until the first go-live fetches them, so a staged domain there stays
verifiable directly, while a serving vhost never loses them (also not
through "Stage again"). The origin-pulls toggle itself is a zone-wide
Cloudflare setting and takes effect at Cloudflare as soon as it is switched
on, staged or not. Go live requires the token for such a domain, fetches
the address ranges and origin CA before rendering the live vhost, and
applies DNS and rules after nginx serves the certificate. For a domain
managed here (mode `dns` or `proxied`), HTTP-01 validation at go-live is
refused unless the name already reaches this server, because the records
are switched only afterwards; use DNS-01. "Stage again" (domain menu or
`stage DOMAIN`) stops the tool from applying DNS and rules for a live
domain, for rolling back; it does not change DNS itself.

## Per domain

Domain > Cloudflare settings, or `getbible.sh cloudflare mode DOMAIN off|dns|proxied`:

| Mode | Effect |
| --- | --- |
| `off` (default) | not managed; no DNS or proxy changes |
| `dns` | the A/AAAA records are created or updated, grey cloud: traffic reaches the origin directly |
| `proxied` | orange cloud, plus the API profile below |

To move an already proxied domain to direct traffic, select `dns`.
Selecting `off` stops management and deliberately leaves existing
Cloudflare configuration as it is.

The API profile for a proxied host is applied using rules that only match
that hostname. Rules carry the exact description `getbible:<domain>`.
The manager updates and deletes these individual rules by ID, and adds
new rules without replacing the shared ruleset. Existing rule positions,
other hosts' rules, their metadata, and concurrent unrelated edits are
preserved. A missing entry point is created with a create request; a
concurrent creation is re-read instead of overwritten. Removal of an absent
rule does nothing, and removal failures are reported.

The profile consists of:

- configuration rule: browser integrity check off, security level
  "essentially off", SSL strict;
- cache rule: `bypass` (default) so every request reaches the origin and its
  logs stay complete, or `respect` to cache per the origin's `Cache-Control`
  (then origin logs only see cache misses). `respect` is available for
  open/metered domains; token-only domains always bypass caching;
- WAF custom rule skipping managed challenges and Cloudflare rate limiting
  for the host (DDoS protection stays on).

Origin side, for proxied hosts:

- `real_ip` restoration from Cloudflare's published ranges, refreshed daily
  by `getbible-cloudflare-ips.timer`, so budgets and unique-caller counts see
  real clients;
- optional authenticated origin pulls (off by default): the selected nginx
  domain verifies Cloudflare's client certificate on HTTPS.

The origin-pulls option uses Cloudflare's shared global AOP certificate and
its matching CA at nginx. Explicitly enabling a domain enables the
zone-wide `tls_client_auth` prerequisite. Applying a domain with this option
enabled also reapplies that prerequisite, including when upgrading an older
installation. A failed API call prevents enabling the domain setting; a
failed prerequisite or CA download during apply is reported as a failure.

Disabling origin pulls in the domain menu removes only that domain's nginx
requirement on the next apply. It leaves Cloudflare's shared feature enabled
for other hosts. The separate CLI command
`getbible.sh cloudflare origin-pulls DOMAIN on|off` explicitly changes the
zone-wide shared feature, so its `off` action affects other hosts using it.
The helper does not change custom zone-level or per-hostname certificates.
See [Cloudflare's global AOP setup](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/global/).

Zone-wide toggles that cannot be scoped to a host (Bot Fight Mode off;
HTTP/3, brotli, TLS 1.2 minimum, always HTTPS) are under System > Cloudflare
origin tools and applied only on explicit request.

## Operator output

Cloudflare menu actions show labeled results and a DNS table with each
record's routing mode and address. The command-line DNS, zone and token
commands continue to print JSON for automation. The helper also accepts
`--human` before a command for the readable form.

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
