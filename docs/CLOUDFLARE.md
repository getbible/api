# Cloudflare

The API is intended to be consumed heavily. Public cache hits are a success:
they reduce origin traffic and may serve more public requests than the origin's
metered budget. Origin logs and budgets count requests that reach nginx; they
are not an accounting system for Cloudflare traffic. Valid bearer tokens keep
the existing unlimited origin access. Authentication stays inside getBible.

Native deployment defaults to Cloudflare `off`. Docker's deployment profile
defaults new domains to `proxied`, edge cache `respect`, and features `free`.
A stored token alone does not enable the proxy or change existing domains.
`DEFAULT_CLOUDFLARE_MODE`, `DEFAULT_CLOUDFLARE_CACHE` and
`DEFAULT_CLOUDFLARE_FEATURES` configure defaults for new domains. Docker exposes
these as `GETBIBLE_DEFAULT_CLOUDFLARE_MODE`,
`GETBIBLE_DEFAULT_CLOUDFLARE_CACHE` and `GETBIBLE_DEFAULT_CLOUDFLARE_FEATURES`.

## Origin route and TLS

For the Docker deployment, Cloudflare connects by HTTPS to OPNsense HAProxy.
HAProxy presents the domain's valid certificate and forwards HTTP to nginx in
the container. Cloudflare uses **Full (strict)**: internal HTTP does not require
Flexible SSL. HAProxy preserves the requested `Host` and `Authorization`, sets
the public HTTPS scheme and normalizes the client address. Multiple domains
share one published container port. See [Docker deployment](DOCKER.md) and
[OPNsense HAProxy](OPNSENSE_HAPROXY.md).

External TLS and Docker require an explicit `SERVER_PUBLIC_IPV4` and/or
`SERVER_PUBLIC_IPV6` firewall WAN address. They never discover an origin from
inside the container. In Compose use `GETBIBLE_SERVER_PUBLIC_IPV4` and
`GETBIBLE_SERVER_PUBLIC_IPV6`. Set IPv6 to `none` for an IPv4-only deployment:
this explicitly removes AAAA records only for the selected API hostname.
An empty IPv6 setting leaves existing AAAA records alone; it does not mean
IPv6 is disabled. IPv4 must exist before the last IPv6 origin can be removed.

With native managed TLS, the manager obtains its certificate before switching
DNS. `install-deps` includes the Certbot Cloudflare DNS plugin. DNS-01 can issue
a certificate while the name still points at another server; HTTP-01 needs the
name already routed here. Settings > Certificate validation selects `auto`,
`http` or `dns-cloudflare`; Issue and Go live can override it. Renewal credentials
live in `/etc/getbible/certbot-cloudflare.ini` and rotate with the stored token.
External TLS delegates certificate issuance and renewal to HAProxy's setup.

## Token and permissions

Settings > Cloudflare API token stores and verifies the token in
`/etc/getbible/cloudflare.conf`, readable by root only. Docker also accepts the
Cloudflare token through its documented environment or mounted-secret setting.
Limit zone permissions to the managed zones:

- Zone: Read; DNS: Edit; Zone Settings: Edit.
- Zone WAF: Edit for host configuration, cache and WAF rules.
- Bot Management: Read to check the non-skippable Bot Fight Mode prerequisite.
- Cache Purge: Purge to protect public-to-token-only transitions.
- SSL and Certificates: Edit for managed certificates/origin pulls when used.
- Page Rules: Read and Workers Routes: Read for public-cache conflict detection.
- Account Workers Scripts: Read for Worker custom-domain inspection. This API
  permission is account-scoped; the inspection requests only the selected
  hostname in its zone. No Worker scripts or routes are changed.

Bot Management: Edit is needed only for the explicit zone-wide `bot-fight`
action. Missing audit permissions fail with Cloudflare's message before host
rules or DNS are changed; inability to inspect configuration is not treated as
an empty zone. A token-only/bypass profile does not need the public-cache audit.

## Per-domain operations

Domain > Cloudflare settings exposes every per-domain setting and the read-only
preflight. In the container replace `getbible` below with
`docker compose exec --user root getbible getbible` from the Compose directory.
Native operators use the installed command or `sudo ./getbible.sh`.

```sh
getbible cloudflare mode api.example.org proxied
getbible cloudflare cache api.example.org respect
getbible cloudflare features api.example.org free
getbible cloudflare check api.example.org
getbible cloudflare apply api.example.org
getbible cloudflare dns api.example.org
getbible cloudflare zone api.example.org
```

| Setting | Behavior |
| --- | --- |
| `mode off` | Stop routine management; retain existing remote records/rules and the recorded public-cache state |
| `mode dns` | Manage A/AAAA, route directly, then remove this host's owned proxy rules |
| `mode proxied` | Apply API rules before switching the hostname to Cloudflare proxying |
| `cache bypass` | Bypass shared-cache lookup and storage for the whole hostname |
| `cache respect` | Cache eligible anonymous GET/HEAD responses according to origin headers |
| `features free` | Free capabilities and rule allowance, including on a paid zone |
| `features paid` | Explicitly allow features and rule allowance verified for the actual paid zone |

CLI mode/cache/features commands apply live domains; the menu saves selections
and has a separate Apply action. Staged domains only save their choices.
`check` reads the current zone plan, rule usage, bot settings and, for public
caching, cache configuration. It changes neither local configuration nor
Cloudflare. The same preflight runs during apply before the first host-rule
mutation. A restart restores the local installation; it does not take over DNS.

## Public JSON caching

`respect` explicitly makes public GET/HEAD URLs cache eligible, including JSON
and **complete query-string URLs**. The default Cloudflare key retains the
hostname, path and query parameters, so different searches and references stay
separate. No Enterprise custom key is needed. The complementary bypass rule
covers any Authorization or Cookie header, even one with an empty value,
non-GET/HEAD methods, truncated request headers, and health/origin-identity
probes. Token-only domains use host-wide bypass regardless of the saved choice.

The rules use `edge_ttl.mode=bypass_by_default` and browser TTL `respect_origin`.
A response without origin cache headers is not cached. The manager sends no
forced edge TTL that overrides `private` or `no-store`. Authentication failures,
rate-limit responses and runtime errors already emit `no-store`; public nginx
404 responses retain their existing short, explicit negative-cache lifetime.
Free/Pro/Business always enable Origin Cache Control. Enterprise public caching
requires explicit paid selection and sends its entitled
`origin_cache_control=true` setting.

Set the desired lifetime at the origin: static domains use `CACHE_TTL` and
`SHA_CACHE_TTL` (new-domain defaults `DEFAULT_CACHE_TTL=3600` and
`DEFAULT_SHA_CACHE_TTL=300`); runtime endpoint settings expose `CACHE_TTL`
(query default 300 seconds, search 60 seconds). New runtime endpoints use
`DEFAULT_QUERY_CACHE_TTL` and `DEFAULT_SEARCH_CACHE_TTL`, exposed in Docker as
`GETBIBLE_DEFAULT_QUERY_CACHE_TTL` and `GETBIBLE_DEFAULT_SEARCH_CACHE_TTL`.
Increasing these lifetimes
increases the period during which a published data change may remain cached.
The existing `stale-while-revalidate` directives can serve public stale content
while it refreshes. Cloudflare may evict an object before its TTL expires.
Authenticated requests still reach nginx and retain appropriate origin caching.

Before enabling public caching, the manager inspects zone caching level,
existing Cache Rules, Page Rules, Worker routes and Worker custom domains.
It reports overlapping rules that drop query parameters, collapse hostnames,
sort parameter order, disable origin controls, or introduce Worker-controlled
caching/authentication. Simple rules for unrelated hosts are left alone;
complex expressions that cannot be proven disjoint are reported for review.
The manager does not rewrite unrelated configuration or silently fall back to
DNS-only routing. Read-only audits cannot prevent another administrator changing
the zone later; re-run `check` after zone changes and verify the public route.

A zone using Ignore Query String must first be returned to Standard. This
explicit action affects the whole zone, and is also in System > Cloudflare
origin tools:

```sh
getbible cloudflare zone-settings api.example.org --cache-level aggressive
```

`aggressive` is Cloudflare's API name for Standard caching, not a forced TTL.
See [cache levels](https://developers.cloudflare.com/cache/how-to/set-caching-levels/),
[default keys](https://developers.cloudflare.com/cache/how-to/cache-keys/),
[rule settings](https://developers.cloudflare.com/cache/how-to/cache-rules/settings/)
and [origin cache control](https://developers.cloudflare.com/cache/concepts/cache-control/).

## Free and paid capabilities

All essential proxying, complete-query public JSON caching, origin TTL handling
and hostname purging work with Free. Paid selection never purchases a plan or
assumes Enterprise capabilities. The zone's actual plan is read before use.
The currently implemented paid options are larger verified rule allowances,
Super Bot Fight Mode skipping when its challenges are active, and Enterprise's
Origin Cache Control setting. Custom error rules, paid cache storage and custom
cache-key features are not automatically enabled by selecting paid.

| Rule type | Free | Pro | Business | Enterprise |
| --- | ---: | ---: | ---: | ---: |
| Cache Rules | 10 | 25 | 50 | 300 |
| Configuration Rules | 10 | 25 | 50 | 300 |
| WAF custom rules | 5 | 20 | 100 | 1,000 |

These are zone-wide allowances shared with other applications and subdomains.
A proxied host uses one configuration rule, one WAF rule, and one cache rule
for bypass or two for respect. Preflight counts existing rules, including
custom WAF rulesets, and required new slots. It stops before mutations when
capacity is insufficient. Updating existing owned rules remains possible at
capacity. It never deletes another application's rules to free space.
[Cache allowance](https://developers.cloudflare.com/cache/how-to/cache-rules/),
[configuration allowance](https://developers.cloudflare.com/rules/configuration-rules/),
[WAF allowance](https://developers.cloudflare.com/waf/custom-rules/).

Rules use exact descriptions `getbible:<domain>` and
`getbible:<domain>:private`. Individual rule IDs are updated rather than replacing
shared rulesets. Cache/configuration rules go last; the host's WAF skip goes
first. Unrelated rule definitions and their relative order are preserved.
Quota or permission changes during apply can still cause a later API call to
fail. The working origin remains available, DNS is not switched, and the error
is reported so Apply can be retried. Security-critical failures are not ignored.

## API security and JSON errors

The host-scoped API profile skips remaining custom challenges, managed WAF rules
and Cloudflare rate limiting, while retaining DDoS protection. It disables Browser
Integrity Check and uses strict origin TLS. Origin authentication, validation and
capacity limits continue to apply on cache misses.

Ordinary **Bot Fight Mode cannot be skipped for one hostname**. If it is enabled
or its settings cannot be read, the profile stops before modifying rules/DNS.
Disabling it is a separate, explicit zone-wide action in System > Cloudflare
origin tools or:

```sh
getbible cloudflare bot-fight api.example.org off
```

Active Super Bot Fight Mode challenges require a verified paid plan and the
explicit per-domain paid selection before a skip is sent. No bot setting is
automatically disabled for other hosts.
[Skip limitations](https://developers.cloudflare.com/waf/custom-rules/skip/options/).

API clients should send `Accept: application/json` or
`Accept: application/problem+json`. Cloudflare supports structured responses for
its documented infrastructure errors on Free when this header is supplied.
This is separate from origin `Content-Type: application/json` and the origin's
RFC 9457 errors. Custom Error Rules are paid features and are not installed by
this profile. Account policies, challenges, independently managed redirects and
Workers can still affect the response; do not promise JSON based on a MIME header
alone. [Cloudflare structured errors](https://developers.cloudflare.com/fundamentals/reference/error-responses/).

## Client addresses and authenticated origin pulls

Native managed-TLS nginx trusts Cloudflare's published address ranges, refreshed
daily, and can verify Cloudflare's shared origin-pull certificate per vhost.
External-TLS nginx trusts the configured HAProxy source addresses instead; it
does not download/install Cloudflare real-IP or client-certificate directives.
HAProxy must accept Cloudflare client-IP headers only from verified Cloudflare
connections, preserve Host/Authorization and normalize the forwarded headers.

Authenticated origin pulls are optional. Enabling them turns on Cloudflare's
shared client certificate for the zone. **With external TLS, configure HAProxy
to verify that certificate before enabling the option.** The HTTP container
cannot perform TLS client-certificate verification. Disabling the domain option
removes its local requirement in managed TLS but does not disable the zone-wide
Cloudflare feature. The separate `cloudflare origin-pulls DOMAIN on|off` command
explicitly changes that shared zone feature.
[Shared AOP setup](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/set-up/global/).

## Verification and protected transitions

Check two domains through one backend port, then through Cloudflare. Verify Host
routing, public HTTPS redirects, client IPs and bearer-token behavior. For a
cacheable URL, anonymous GETs should progress from MISS to HIT with Age increasing;
compare different query strings and confirm their bodies remain distinct. An
authorized request and a POST must reach the origin even when an anonymous GET
for that URL is cached. Health and origin-identity checks must remain fresh.

Before changing a proxied domain to token-only, the manager installs host-wide
cache bypass and purges the hostname. A missing token, rejected bypass or failed
purge aborts activation. The last successfully applied public-cache policy is
persistent: selecting `mode off` does not erase it. A later token-only transition
still protects that previously managed cache, without changing DNS. A successful
DNS-only sync records direct routing and clears the need for this old-edge
protection; merely selecting a mode or a failed DNS update does not. It never
substitutes a zone-wide purge. A separate pending marker also records an uncertain
public-cache write: a lost Cloudflare response cannot leave an earlier protected
state trusted. A successful protected bypass-and-purge clears that marker. Old content
already downloaded by clients cannot be recalled. Correct the reported permission
or quota problem and retry Apply; verify an anonymous request to formerly cached
data now returns the origin's JSON authentication error. Documentation and health
remain public as defined by the access model, although token-only domains bypass
shared caching for the entire hostname.
