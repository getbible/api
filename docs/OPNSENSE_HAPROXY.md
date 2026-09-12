# OPNsense HAProxy in front of getBible

This is the step-by-step external-TLS setup for native and Docker installations.
Use it with [DOCKER.md](DOCKER.md) and [CLOUDFLARE.md](CLOUDFLARE.md).
The backend-pool tables follow the OPNsense form, including advanced fields.

The forwarding setup accepts both Cloudflare-proxied and direct HTTPS requests
for configured domains. It does not require Cloudflare-only firewall rules,
hardcoded Cloudflare address lists, or HAProxy request-denial rules. nginx
continues to enforce the configured API access modes and dashboard authentication.

## Setup order

1. [DNS, certificates and network access](#1-dns-certificates-and-network-access).
2. [Prepare the getBible HTTP origin](#2-prepare-the-getbible-http-origin).
3. [Create the Real Server](#3-create-the-real-server).
4. [Create the Health Monitor](#4-create-the-health-monitor).
5. [Create the Backend Pool](#5-create-the-backend-pool).
6. [Configure headers and automatic Cloudflare address recognition](#6-headers-and-trust).
7. [Connect hostname conditions, routing rules and the HTTPS Public Service](#7-hostname-conditions-routing-rules-and-the-public-service).
8. [Test, apply and go live](#8-test-apply-and-go-live).

If certificate automation and a shared HTTPS Public Service already work, reuse
them. Check certificate coverage and add routing for the new domains. A DNS record
alone does not necessarily enroll a domain in the appliance's certificate job.

The illustrative addresses below are unrelated to any operator's deployment:

| Purpose | Example |
| --- | --- |
| Docker/native origin LAN address | `10.0.0.20` |
| Published HTTP origin port | `8080` |
| HAProxy LAN source address | `10.0.0.1` |
| Public firewall IPv4 | `203.0.113.20` |
| Public domains | `api.example.org`, `query.example.org`, `dashboard.example.org` |

Replace these examples locally. Keep credentials and actual infrastructure
details outside the repository. Field names can differ between plugin versions:
Real Servers/Servers, Backend Pools/Backends, Public Services/Frontends and
Health Monitors/Health Checks refer to the same respective objects.
The examples target HAProxy 3.2 and the linked OPNsense plugin forms.

## 1. DNS, certificates and network access

- Install/enable `os-haproxy` under **System > Firmware > Plugins** if necessary.
  The remaining HAProxy objects are under **Services > HAProxy > Settings**.
- Point each intended hostname at the firewall's reachable public address.
  Use Cloudflare's proxied mode when its edge caching is wanted. A DNS-only
  record or an explicit direct HTTPS connection can use the same HAProxy route.
- On OPNsense, reuse the existing ACME/certificate automation, or install
  `os-acme-client` and configure an ACME account, Cloudflare DNS-01 validation,
  the domain certificate and renewal automation that updates HAProxy.
  Select the resulting certificates on the HTTPS Public Service. Keep that
  automation's credentials on OPNsense.
- With Cloudflare proxying, use **Full (strict)** and a valid matching certificate
  on HAProxy. Internal plaintext HTTP does not require Flexible SSL. For normal
  browser access directly to HAProxy, use a publicly trusted certificate such
  as an ACME certificate; a Cloudflare Origin CA certificate alone is not
  trusted by ordinary browsers.
- Allow the intended public HTTPS traffic to HAProxy's listening address/port.
  When HAProxy listens on the firewall itself, use a WAN pass rule to that
  listener; do not forward that same port past HAProxy to the Docker host.
  Keep existing shared listeners, management access and routing intact.
- Allow HAProxy to reach the origin's LAN HTTP port. Publish that origin port
  on a reachable LAN address. A proxy on another machine cannot reach a
  Docker port bound only to `127.0.0.1`. The plaintext origin port is not the
  public HTTPS listener.

### IPv4-only origins and IPv6 visitors

An IPv4-only origin can serve visitors who connect to Cloudflare over IPv6.
Those are separate connections: Cloudflare accepts the visitor connection and
connects to the configured IPv4 origin. This is proxying, not an HTTP redirect.

For an IPv4-only origin, configure its real public IPv4 in the Cloudflare
A record and do not add an origin AAAA record for an unreachable IPv6 address.
Cloudflare can still advertise its own IPv6 edge addresses for a proxied
hostname. The visitor's IPv6 address can also travel as header text over the
IPv4 connection; it must not be replaced with a made-up IPv4 address.

When getBible manages that hostname's DNS, set
`GETBIBLE_SERVER_PUBLIC_IPV6=none` in Compose, or `SERVER_PUBLIC_IPV6=none`
in native configuration. This removes the managed hostname's origin AAAA
records; an empty setting preserves existing records. It does not turn off
Cloudflare's edge IPv6 compatibility. Do not enable Pseudo IPv4's
**Overwrite Headers** mode when original visitor addresses are wanted.

See [Cloudflare IPv6 compatibility](https://developers.cloudflare.com/network/ipv6-compatibility/)
and [visitor-IP headers](https://developers.cloudflare.com/fundamentals/reference/http-headers/).

## 2. Prepare the getBible HTTP origin

For the example Docker deployment, use these values in its private `.env`:

~~~dotenv
GETBIBLE_BIND_ADDRESS=10.0.0.20
GETBIBLE_HTTP_PORT=8080
GETBIBLE_TLS_MODE=external
GETBIBLE_TRUSTED_PROXY_CIDRS=10.0.0.1/32
GETBIBLE_PUBLIC_SCHEME=https
GETBIBLE_ORIGIN_HTTP_PORT=80
GETBIBLE_SERVER_PUBLIC_IPV4=203.0.113.20
GETBIBLE_SERVER_PUBLIC_IPV6=none
~~~

Compose maps host port 8080 to container port 80. HAProxy connects to the host
port. For native deployment, use the equivalent external-TLS settings and
connect HAProxy to nginx's configured origin port; there is no Docker mapping.
See [Docker environment settings](DOCKER.md#3-set-the-installation-settings)
and [native installation](INSTALL.md).

Start the container/native services and configure the domains and endpoints
through the existing menu. The environment does not create those domains.
One backend IP/port serves every static, query, search and dashboard domain:
nginx selects the domain from `Host`, then the endpoint from its path.
Keep `Host` as the requested public name.

`TRUSTED_PROXY_CIDRS` identifies the HAProxy connection source that nginx
actually receives. It is not the public WAN IP, the visitor IP, or the entire
LAN. Use the exact proxy addresses and the appropriate /32 or /128 masks.

## 3. Create the Real Server

Open **Real Servers > Add**, enable advanced fields where needed, and save:

| Field | Value |
| --- | --- |
| Enabled | Checked |
| Name | `getbible_origin` |
| Description | `getBible HTTP origin` |
| FQDN or IP | `10.0.0.20` |
| Port | `8080` |
| SSL | Unchecked |
| Source address | `10.0.0.1`, without a CIDR suffix |
| Other fields | Defaults unless the deployment needs an explicit change |

The backend pool below sets **Proxy Protocol: None**. The image expects
ordinary HTTP with headers, not a PROXY-protocol preamble.

## 4. Create the Health Monitor

Open **Health Monitors > Add** and save:

| Field | Value |
| --- | --- |
| Name | `getbible_http` |
| Check type | HTTP |
| SSL preferences | Disable SSL |
| SSL SNI | Empty |
| Check interval | `5000` milliseconds |
| Port to check | Empty; use the Real Server port |
| HTTP method | GET |
| Request URI | `/healthz` |
| HTTP version | HTTP/1.1 |
| HTTP host | `api.example.org`, replaced by one deployed domain |
| Custom HTTP check > Enabled | Checked |
| Expression | Match HTTP status (`status`) |
| Value | `200` |
| Negate condition | Unchecked |

The health monitor's Host applies only to its own checks; it must not become
a rule rewriting ordinary requests to that one domain. A successful check
verifies the nginx listener/vhost. It does not establish that every query/search
runtime is ready; use getBible's deployment readiness checks for that.

## 5. Create the Backend Pool

Open **Backend Pools > Add** and turn on **advanced mode**. Save the pool
before creating the hostname-routing rule that must select it.

### General fields

| Field | Value |
| --- | --- |
| Enabled | Checked |
| Name | `getbible` |
| Description | `getBible API origin` |
| Mode | HTTP (Layer 7) |
| Balancing Algorithm | Round Robin |
| Random Draws | Leave default; unused with Round Robin |
| Proxy Protocol | None |
| Servers | Select `getbible_origin` |
| FastCGI Application | None |
| Resolver | None |
| Resolver Options | Empty |
| Prefer IP Family | None; the Real Server already uses a literal IPv4 address |
| Source address | `10.0.0.1`, without /32 |

The pool's Source address takes precedence over the Real Server setting.
With one server, the balancing algorithm does not distribute work among
getBible's internal processes; the container/native runtime manages those.

### Health Checking

| Field | Value |
| --- | --- |
| Enable Health Checking | Checked |
| Health Monitor | `getbible_http` |
| Log Status Changes | Checked |
| Check Interval | `5000` milliseconds |
| Down Interval | `5000` milliseconds |
| Unhealthy Threshold | `3` |
| Healthy Threshold | `2` |
| E-Mail Alert | None |
| Use Proxy Protocol | Disable for Health Check |

A checked **Enable Health Checking** with **Health Monitor: None** does not
generate an active health check. Select the monitor.

### HTTP(S), Persistence and Basic Authentication

| Field | Value |
| --- | --- |
| Enable HTTP/2 | Unchecked for this HTTP/1.1 origin |
| HTTP/2 without TLS | Unchecked |
| Advertise Protocols (ALPN) | HTTP/1.1 only; unused with backend SSL disabled |
| Forwarded header (RFC7239) | Unchecked |
| Forwarded header parameters | Empty |
| X-Forwarded-For header | Unchecked; explicit rules below set it |
| Persistence type | None |
| Stick-table > Table type | None |
| Stored data types | Empty |
| Remaining stick-table fields | Defaults/empty; unused when Table type is None |
| Basic Authentication > Enable | Unchecked |
| Allowed Users / Allowed Groups | Empty |

Set **Table type: None** before **Persistence type: None** if changing
persistence hides the table section. Clearing persistence alone can leave a
stick table configured. getBible's dashboard session cookie still passes
normally; it does not require HAProxy persistence or Basic Authentication.
Frontend HTTP/2 can remain enabled independently of backend HTTP/1.1.

### Tuning Options, Rules and Error Messages

| Field | Value |
| --- | --- |
| Connection Timeout | `5s` |
| Check Timeout | `5s` |
| Server Timeout | `75s` |
| Retries | Leave default |
| Option pass-through | Paste the block in section 6 |
| Default for server | Empty |
| Use Frontend port | Unchecked; retain the Real Server's origin port |
| HTTP reuse | Safe |
| Enable Caching | Unchecked |
| Select Rules | `getbible_mark_cloudflare` after creating it in section 6 |
| Select Error Messages | Optional proxy error responses described below |

The timeout profile accommodates the documented search deadline up to 60 seconds
with transfer headroom. Revisit it if inner application/nginx deadlines change.
HAProxy need not cache responses: nginx and Cloudflare own the API cache policies.

## 6. Headers and trust

The HTTPS Public Service and this backend must not append an automatic
X-Forwarded-For header after the explicit rules below. Leave that checkbox off
in both places. If a shared frontend currently enables it for other sites,
first put equivalent forwarding behavior in those sites' backend pools, then
disable the shared frontend checkbox. Do not change their client-IP policies.

The following setup assumes HAProxy sees the actual connecting peer in `src`.
Check existing frontend rules for `set-src`, removed Cloudflare headers or
another proxy hop before using it. A local frontend chain must preserve the
original peer correctly; trusting an arbitrary incoming X-Forwarded-For chain
is not a substitute.

### Automatic Cloudflare recognition

This uses the plugin's existing **Map Files > Download URL** support.
The address lists identify which peers may supply a Cloudflare visitor header;
they are not an allowlist that blocks everyone else.

Under **Map Files**, create:

| Field | IPv4 source list | IPv6 source list |
| --- | --- | --- |
| Name | `getbible_cloudflare_v4` | `getbible_cloudflare_v6` |
| Type | `ip` | `ip` |
| Content | Empty | Empty |
| Download URL | `https://www.cloudflare.com/ips-v4/` | `https://www.cloudflare.com/ips-v6/` |

For a strictly IPv4 origin listener, the IPv4 list is sufficient even when
visitors use IPv6 to reach Cloudflare. Add the IPv6 source list if HAProxy
also accepts origin connections over IPv6.

Create a **Condition** per source list:

| Field | IPv4 condition |
| --- | --- |
| Name | `getbible_from_cloudflare_v4` |
| Condition type / expression | `src - Source IP matches specified IP` |
| Source IP | Empty |
| Mapfile | `getbible_cloudflare_v4` |

Use the IPv6 map in the equivalent IPv6 condition when enabled. These are
additional source conditions, separate from the hostname conditions in step 7.
The plugin supports an empty Source IP when Mapfile supplies the patterns.
An OPNsense firewall alias is not automatically an HAProxy map file.

Create a **Rule**:

| Field | Value |
| --- | --- |
| Name | `getbible_mark_cloudflare` |
| Match mode | IF |
| Conditions | The Cloudflare source condition(s) above |
| Logical operator | OR when selecting both conditions |
| Execute function / rule type | Custom rule (option pass-through) |
| Custom rule | The single line below |

~~~haproxy
http-request set-var(txn.gb_cf_peer) str(yes)
~~~

Select this rule under the getBible **Backend Pool > Select Rules**.
Do not put a conditional suffix on that custom line yourself: the GUI generates
it from the chosen conditions. The plugin emits selected rules before the
backend's Option pass-through, so this marker is available to the block below.
Do not replace the rule with an unconditional marker.

Under **System > Settings > Cron**, schedule **Reload HAProxy service** daily,
for example minute `17`, hour `3`, other date fields `*`, enabled, no parameters.
Choose the existing reload task, not a stop/start task. It downloads the map
files through the plugin's built-in mechanism; no custom updater script or
manually copied address list is required. This is a reload of the HAProxy
service, including shared frontends, not just an in-memory ACL update.

The plugin downloads on reload/restart and falls back to **Content** if the
download fails. It does not retain the last downloaded list as that fallback.
Empty fallback content gives an empty source match list. Forwarding then uses
the connection-source address; it does not reject a request because the list
is empty, stale or could not be downloaded. During that fallback, Cloudflare visitors
may share proxy addresses in logs, rate limits and dashboard IP blocking.
A malformed successful download can fail the configuration test; review the
plugin log and generated configuration when diagnosing reload failures.

These behaviors are documented in the
[Map File form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogMapfile.xml)
and implemented by the
[map exporter](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/scripts/OPNsense/HAProxy/exportMapFiles.php).

### Backend Option pass-through

Paste this entire block into **getBible Backend Pool > Tuning Options >
Option pass-through**. Only the HTTPS Public Service should route requests to
this pool; an HTTP listener should redirect to HTTPS separately.

~~~haproxy
http-request set-var(txn.gb_client_ip) src
http-request set-var(txn.gb_client_ip) req.hdr_ip(CF-Connecting-IP) if { var(txn.gb_cf_peer) -m str yes } { req.hdr_cnt(CF-Connecting-IP) eq 1 } { req.hdr_ip(CF-Connecting-IP) -m found }
http-request del-header Forwarded
http-request set-header X-Forwarded-For %[var(txn.gb_client_ip)]
http-request set-header X-Real-IP %[var(txn.gb_client_ip)]
http-request set-header X-Forwarded-Proto https
http-request set-header X-Forwarded-Host %[req.hdr(Host)]
http-request del-header CF-Connecting-IP
http-request del-header X-GetBible-Token-Id
~~~

There are no `http-request return` or `deny` actions in this forwarding
configuration. Direct requests use the actual connection-source IP and proceed
to nginx. Recognized Cloudflare connections use their single valid visitor-IP
header. Missing, duplicate or invalid visitor headers fall back to the peer
address rather than stopping the request. A direct caller cannot choose its
rate-limit or dashboard-block identity by inventing a Cloudflare header.

| Information | Behavior |
| --- | --- |
| Host | Preserved automatically; selects the correct nginx domain |
| Authorization / bearer token | Preserved to nginx for validation; never capture it in HAProxy logs |
| Cookie / Set-Cookie | Preserved; dashboard sessions do not need proxy authentication |
| Path, query string, request body | Forwarded without rewriting |
| X-Forwarded-For / X-Real-IP | One normalized address chosen above |
| X-Forwarded-Proto | `https`, because TLS terminates on the HTTPS frontend |
| X-Forwarded-Host | The requested Host |
| Forwarded / CF-Connecting-IP | Removed after normalization |
| X-GetBible-Token-Id | Incoming value removed; nginx supplies its validated internal ID |

A Joomla-style `X-Forwarded-SSL: on` line is unnecessary for getBible.
Setting Host to its own current value is redundant. Do not set it to the
backend IP, or to one hostname shared by all requests.

For simple forwarding without Cloudflare address restoration, omit the map
files, marker rule and scheduled refresh, and omit only the second line of the
block (the conditional visitor-IP override). Traffic still passes, but requests
through Cloudflare are identified by the Cloudflare peer address. That groups
visitors in per-IP budgets and dashboard blocks, so use automatic recognition
when per-visitor analytics and policies are required.

### What nginx already handles

In external-TLS mode nginx trusts the configured HAProxy peer, consumes the
normalized X-Forwarded-For value, validates bearer tokens and enforces API
access modes/limits. The dashboard applies its own sign-in and session rules.
The native managed-TLS Cloudflare integration refreshes nginx's Cloudflare
ranges separately; external-TLS nginx does not do that job for HAProxy.

Cloudflare-only access controls and Authenticated Origin Pulls are separate,
optional deployment policies. They are not prerequisites for this forwarding
setup. Requiring Cloudflare's client certificate would intentionally prevent
ordinary direct HTTPS clients from using that listener.

## 7. Hostname conditions, routing rules and the Public Service

1. Under **Conditions**, create a Host-matches condition for each configured
   domain, or one condition with all supported exact hostnames. Match the HTTP
   Host header; do not use a URL path or the backend IP as a hostname.
2. Under **Rules**, create `getbible_route`: IF any of those hostname conditions
   match (logical **OR**), execute **Use specified Backend Pool** and select
   `getbible`. AND would require one request to match different exact hostnames.
3. Open the existing HTTPS **Public Service** or create one when none exists.
   Use the intended WAN listener at port 443, type **HTTP / HTTPS (SSL
   offloading)**, enable SSL offloading, and select certificates covering all
   the routed domains. Do not create a second listener on the same address/port.
4. Attach `getbible_route` under the Public Service's **Select Rules**. Keep its
   existing unrelated routes. The hostname routing rule belongs here; the
   Cloudflare marker rule belongs in the getBible backend.
5. Leave automatic **X-Forwarded-For** insertion off as described in section 6.
   Do not add frontend Basic Authentication for the API or overwrite Host or
   Authorization. Use initial client timeout `75s`, HTTP request timeout
   `10s` and HTTP keep-alive timeout `15s`, accounting for existing shared sites.
6. If HTTP port 80 is offered, use its existing HTTPS redirect behavior,
   preserving any certificate challenge routes. Do not attach the HTTPS-only
   getBible backend as a plaintext public route.

Every getBible domain uses the same pool. HTTPS SNI selects a certificate on
HAProxy, while the preserved HTTP Host selects the nginx vhost. A dashboard
domain additionally needs its existing Telegram/password/enable setup inside
getBible; proxy routing does not enable it by itself. See [DASHBOARD.md](DASHBOARD.md).

## JSON errors, caching and timeouts

nginx and the runtime already produce application problem responses. Preserve
their status codes and response headers, including Content-Type, Cache-Control,
ETag, Last-Modified, Retry-After and CORS. HAProxy does not need duplicate
application-error or request-blocking rules.

HAProxy can itself generate errors before nginx answers, such as 503 when the
origin is unavailable. To give those errors the same JSON presentation, create
**Error Messages** and select them on the relevant pool/service. This changes
error formatting, not which callers can reach the API. The plugin expects a
complete HTTP response, for example:

~~~http
HTTP/1.1 503 Service Unavailable
Content-Type: application/problem+json
Cache-Control: no-store
Connection: close

{"type":"about:blank","title":"Service Unavailable","status":503}
~~~

Use the corresponding status/title for supported proxy error codes. Preserve
the blank line between headers and body. Leave custom error selections empty
until configured; that does not affect normal origin JSON responses. On a
shared frontend, choose frontend-wide error formatting deliberately. TLS
handshake failures have no HTTP body, and HAProxy cannot rewrite errors
generated by Cloudflare before the request reaches it.

Keep HAProxy caching off. Apply the existing per-domain Cloudflare cache policy
in [CLOUDFLARE.md](CLOUDFLARE.md), including bearer/token-only bypass. Direct
requests naturally bypass edge caching and remain subject to origin policy.
Search deadlines and the various proxy inactivity timeouts are different
controls; preserve headroom when changing any inner timeout.

## 8. Test, apply and go live

1. Run OPNsense's **Test syntax / configuration test**. Inspect the generated
   configuration: source-map conditions must guard the marker action, the
   marker must precede the backend header block, and no frontend/backend
   automatic forwardfor option may append a second client address. Confirm
   the server uses HTTP at the intended port with no PROXY preamble.
2. Apply/reload after that test succeeds. Check **HAProxy > Statistics** for
   a healthy backend. If down, verify origin connectivity and the health
   monitor's Host. A 301 usually indicates the wrong TLS mode or vhost.
3. From an allowed origin-side operator path, test two configured domains:

   ~~~sh
   curl -i -H 'Host: api.example.org' http://10.0.0.20:8080/healthz
   curl -i -H 'Host: query.example.org' http://10.0.0.20:8080/versions.json
   ~~~

4. Use getBible's explicit Go live for the prepared domain. In external TLS,
   certificate provisioning is owned by HAProxy; the manager checks the local
   HTTP origin and verifies public HTTPS after activation.
5. Check both public hostnames and the dashboard over HTTPS. Verify correct
   endpoint discovery and redirects without internal addresses or ports.
6. Test direct HTTPS while preserving both SNI and Host:

   ~~~sh
   curl --resolve api.example.org:443:203.0.113.20 https://api.example.org/healthz
   ~~~

   Use an external test location if LAN reflection is not configured. With a
   publicly trusted certificate, no insecure TLS override is necessary. An
   existing external firewall/Cloudflare-only policy may still block direct
   traffic independently of the forwarding rules in this guide.
7. Request an uncached API resource through Cloudflare and directly; check
   origin analytics for the actual visitor addresses. Deliberately forged
   X-Forwarded-For and CF-Connecting-IP headers on the direct request must not
   change that direct client's identity. Confirm IPv6 visitor addresses remain
   intact even with an IPv4-only origin. Edge cache hits do not reach origin logs.
8. Test token-only data without a token, with a valid token and after revocation.
   Keep secrets out of URLs/logs. Verify anonymous cache behavior separately
   from token-bearing bypass and dashboard sessions.
9. Confirm the map download and daily reload are configured. On a disposable
   proxy, verify empty source lists still forward direct/proxied requests with
   peer-IP fallback. Do not simulate outages on a shared production listener.

These checks verify the installed appliance and its route. Repository tests
and configuration examples alone cannot establish its live settings.

## Primary references

- [OPNsense HAProxy model](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/models/OPNsense/HAProxy/HAProxy.xml)
- [Real Server form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogServer.xml)
- [Backend Pool form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogBackend.xml)
- [Health Monitor form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogHealthcheck.xml)
- [Condition form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogAcl.xml)
- [Rule form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogAction.xml)
- [Public Service form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogFrontend.xml)
- [Generated configuration and action ordering](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/service/templates/OPNsense/HAProxy/haproxy.conf)
- [HAProxy reload action](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/service/conf/actions.d/actions_haproxy.conf)
- [HAProxy configuration manual](https://docs.haproxy.org/3.2/configuration.html)
- [nginx real-IP module](https://nginx.org/en/docs/http/ngx_http_realip_module.html)
- [Cloudflare Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
