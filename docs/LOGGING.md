# Logging and analytics

Everything about a request is logged; only bearer tokens are not.

## Files

| File | Written by | One line per |
| --- | --- | --- |
| `/var/log/getbible/<domain>/access.log` | nginx | request: time, host, endpoint, version, client address, method, full URI including the query string, status, bytes, request length, timing, upstream time, proxy cache state, referer, user agent, request id, token id, scheme, protocol, TLS version, Cloudflare country |
| `/var/log/getbible/<domain>/error.log` | nginx | warning or error |
| `/var/log/getbible/<domain>/app/<label>.log` | the runtime endpoint's service (`app.log` for a domain from before endpoints had records) | request: everything above plus the parsed reference, translation, search string, criteria, kind, totals, and the problem code on errors |
| systemd journal | services, sync, timers | lifecycle messages |

All lines are JSON. The runtime apps also send warnings and errors to the
journal.

## Rotation

`/etc/getbible/logrotate.conf` is run every hour by
`getbible-logrotate.timer` with its own state file, independent of the
distribution's daily logrotate. A log is rotated once it reaches the
configured size (1 GB by default), compressed, date-stamped and moved to
`<domain>/archive/`. The configured number of archives (30 by default) is
kept; beyond that the oldest is deleted on each rotation. Each rotation sends
a Telegram message with the archive count and a warning once the ceiling is
reached. Change both values under Settings > Log retention or Logs >
Retention. The archives are what a dashboard system should collect.

## Analytics

Analytics > window, or:

```sh
getbible.sh analytics [--window today|24h|7d|30d|all] [--domain D] [--json]
```

Reads the live log and the archives inside the window, per domain and
combined:

- **total calls**: every request except CORS preflights (`OPTIONS`);
- **unique callers**: distinct token ids, or distinct client addresses when
  no token was presented, IPv6 collapsed to its /64; the combined figure is
  the union across domains, so one client using two domains counts once;
- status classes, rate-limited requests, bytes, latency percentiles, proxy
  cache hit ratio, top paths, versions, tokens, user agents, calls per day.

Reports never print a raw address. `--json` gives the same data for other
tools.
