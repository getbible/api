# OPNsense HAProxy in front of getBible

Use this with [DOCKER.md](DOCKER.md) and [CLOUDFLARE.md](CLOUDFLARE.md).
The examples use Docker host `192.168.10.20:8080`, HAProxy's LAN source
`192.168.10.1`, and example domains. Replace these with the actual addresses
and domains before applying them.

## Routing and protocol contract

Cloudflare connects to HAProxy on HTTPS/443. HAProxy terminates TLS and
forwards HTTP to the Docker host's published port; nginx inside the container
chooses the virtual host using `Host`. A backend IP and port identify the
connection destination, not the request's hostname. No per-domain or
per-endpoint port is required.

Use **HTTP / HTTPS (SSL offloading)**, not TCP passthrough. TLS SNI selects
the certificate on HAProxy; HTTP `Host` selects the domain in nginx. These
are separate stages. Keep Cloudflare SSL mode **Full (strict)** and install
valid domain certificates on HAProxy through the existing OPNsense certificate
automation. Container TLS mode is `external`; the container HTTP port is 80
unless explicitly changed in both nginx and Compose.

The interface names below were checked against the OPNsense plugin's source.
The equivalent directives target HAProxy 3.2 syntax. A particular appliance's
OPNsense, os-haproxy and HAProxy versions still need to be recorded and its
generated configuration validated. These instructions do not claim an appliance
has been configured by this repository.

## OPNsense objects

In **Services > HAProxy**, create or adapt these objects. Enable advanced
fields where necessary. Preserve unrelated frontends and rules.

| Object | Settings |
| --- | --- |
| Real Server `getbible_origin` | Address `192.168.10.20`, port `8080`, SSL disabled, PROXY protocol disabled |
| Health Monitor `getbible_http` | HTTP, GET, `/healthz`, HTTP/1.1, HTTP host set to one deployed hostname; expect status 200; SSL disabled |
| Backend Pool `getbible` | HTTP mode, server above, health checking enabled using that monitor; no cookie persistence or HAProxy cache |
| Public Service | Listen on the intended WAN address at 443; type HTTP/HTTPS SSL offloading; SSL offloading enabled; select all relevant certificates |
| Hostname conditions/rules | Match the getBible domains and route all of them to the same backend pool |
| Backend timeouts | Connection `5s`, Check `5s`, Server `75s` as an initial profile |
| Public-service timeouts | Client `75s`, HTTP Request `10s`, HTTP Keep-Alive `15s` as an initial profile |

Leave **X-Forwarded-For header** insertion and **Forwarded header (RFC7239)**
insertion disabled where the normalization rules below set the headers.
Otherwise automatic append behavior can reintroduce a Cloudflare proxy address
or an untrusted address chain. Basic Authentication is also disabled: getBible
already enforces its bearer-token access modes.

The health monitor's **HTTP host** only belongs to generated health requests.
It must not become a rule that rewrites `Host` on ordinary requests. One nginx
health response checks that origin's listener; it does not prove every runtime
is ready. Use getBible status/readiness checks when deploying applications.

Restrict access to the published LAN port to the proxy and intended operator
networks. A separate OPNsense machine cannot reach a port bound only to Docker
host loopback. For a Cloudflare-only public API, allow HTTPS from Cloudflare's
current IPv4/IPv6 ranges and reject arbitrary direct origin connections. Keep
the WAN allowlist current from Cloudflare's published ranges; an OPNsense PF
alias is not automatically an HAProxy ACL file.

## Headers and trust

| Header | HAProxy to nginx | nginx to runtime |
| --- | --- | --- |
| `Host` | Preserve the public domain; never replace it with the backend IP | Selected public hostname |
| `Authorization` | Preserve unchanged; never capture it in logs | Removed after nginx token validation |
| `CF-Connecting-IP` | Read only after verifying the TCP peer is Cloudflare, then discard | Not an authentication or direct trust input |
| `X-Forwarded-For` | Replace with one validated client address | Constructed from nginx's trusted client identity |
| `X-Real-IP` | Replace with the same validated address | nginx's trusted client identity |
| `X-Forwarded-Proto` | Set `https` on the TLS frontend | Public scheme, not the plaintext backend scheme |
| `X-Forwarded-Host` | Replace with the actual `Host` if supplied | nginx's selected hostname |
| `X-GetBible-Token-Id` | Remove any incoming value | nginx supplies its validated token ID |

Configure `GETBIBLE_TRUSTED_PROXY_CIDRS=192.168.10.1/32` in the Docker
deployment example, using the actual source address nginx receives. Do not
trust every private network or trust arbitrary forwarded headers. Container
nginx's trusted peers are HAProxy's addresses; Cloudflare's public addresses
belong at HAProxy's external trust boundary. Native direct-Cloudflare TLS uses
the existing direct Cloudflare real-IP setup instead.

Use frontend **Option pass-through** for the exact normalization directives
if the installed plugin's Rules interface cannot express the checks as ordered
HTTP request actions. In a frontend shared with unrelated sites, scope the
rules to the getBible hostname condition. The following block is for a
dedicated getBible frontend:

```haproxy
# An operator-maintained file containing current Cloudflare IPv4/IPv6 CIDRs.
acl from_cloudflare src -f /conf/haproxy/cloudflare-ips.lst
acl cf_ip_once req.hdr_cnt(CF-Connecting-IP) eq 1
acl cf_ip_valid req.hdr_ip(CF-Connecting-IP) -m found

http-request return status 403 content-type application/problem+json string '{"type":"about:blank","title":"Forbidden","status":403}' hdr Cache-Control no-store unless from_cloudflare
http-request return status 400 content-type application/problem+json string '{"type":"about:blank","title":"Invalid client address","status":400}' hdr Cache-Control no-store unless cf_ip_once cf_ip_valid

http-request set-var(txn.getbible_client_ip) req.hdr_ip(CF-Connecting-IP)
http-request del-header Forwarded
http-request set-header X-Forwarded-For %[var(txn.getbible_client_ip)]
http-request set-header X-Real-IP %[var(txn.getbible_client_ip)]
http-request set-header X-Forwarded-Proto https
http-request set-header X-Forwarded-Host %[req.hdr(Host)]
http-request del-header CF-Connecting-IP
http-request del-header X-GetBible-Token-Id
```

The file path is an example, not a file shipped or automatically maintained by
getBible. Create and maintain it on OPNsense, or use the equivalent source-IP
conditions in the plugin. When editing a shared frontend, do not paste the
unconditional block over other applications: put the normalization in the
getBible backend, retaining the original peer check, or add the same getBible
hostname condition to every action. Ensure all trust checks precede rewriting.

Public requests sent directly to this Cloudflare-only frontend are rejected.
For controlled direct-origin diagnosis, use a separate LAN listener with its
own source allowlist and `src` as client identity; do not temporarily trust
Cloudflare headers from every source. Do not enable Cloudflare Pseudo IPv4's
header-overwrite mode if actual IPv6 caller addresses must be retained.

Equivalent backend configuration, showing that the domain is not rewritten:

```haproxy
backend getbible
    mode http
    timeout connect 5s
    timeout server 75s
    timeout check 5s
    option httpchk
    http-check send meth GET uri /healthz ver HTTP/1.1 hdr Host api.example.org
    http-check expect status 200
    server getbible_origin 192.168.10.20:8080 check
```

Do not enable PROXY protocol unless both ends are intentionally reconfigured
to speak it. The provided image expects ordinary HTTP with trusted headers.

## JSON errors, caching and timeouts

Preserve origin response status and headers, including `Content-Type`,
`Cache-Control`, `ETag`, `Last-Modified`, `Retry-After`, CORS and cache-status
headers. Do not apply an HTML error-page rewrite to upstream JSON. HAProxy
caching is unnecessary; nginx and Cloudflare own the documented cache policies.

Configure HAProxy's own error messages separately under **Error Messages** and
select them on the getBible Public Service and Backend Pool. The plugin expects
a complete HTTP response. For status 503, for example:

```http
HTTP/1.1 503 Service Unavailable
Content-Type: application/problem+json
Cache-Control: no-store
Connection: close

{"type":"about:blank","title":"Service Unavailable","status":503}
```

Provide corresponding status/title bodies for supported proxy-generated 400,
403, 408, 429, 500, 502, 503 and 504 responses. Preserve the blank line between
headers and body. Custom error files change HAProxy-generated errors, not
upstream application responses. Inspect the generated configuration and use
the plugin's configuration test before Apply. TLS-handshake failures have no
HTTP response body to convert to JSON.

Application search deadlines, nginx proxy timeouts and HAProxy inactivity
timeouts serve different purposes. Set HAProxy's server timeout above nginx's
configured upstream timeout and the application deadline, with transfer
headroom. The examples allow up to 60-second configured search deadlines; do
not blindly copy `75s` while independently raising inner deadlines. Keep
connection/header timeouts short enough to avoid idle clients occupying the
origin indefinitely.

Cloudflare-generated errors and browser challenges are a separate layer.
Clients should send `Accept: application/json` or `application/problem+json`;
apply the API rules in [CLOUDFLARE.md](CLOUDFLARE.md). HAProxy cannot change an
error Cloudflare creates before contacting it.

Optional Authenticated Origin Pulls client-certificate verification belongs
on HAProxy because it terminates Cloudflare's TLS. Import the appropriate CA
and configure Public Service **Client Certificate Auth** there. Do not enable
container nginx client-certificate verification on its plaintext HTTP listener.
If the frontend serves unrelated sites, account for their client-certificate
requirements before enabling a frontend-wide requirement.

## Acceptance before public launch

1. Record OPNsense, os-haproxy and HAProxy versions; run the configuration test.
2. Confirm HAProxy can reach the Docker LAN port and the monitor sends the
   correct `Host`. A 301 health response usually means the wrong TLS mode;
   a default-site response usually means a missing or wrong hostname.
3. Request two configured domains at the same backend IP and port:

   ```sh
   curl -i -H 'Host: api.example.org' http://192.168.10.20:8080/versions.json
   curl -i -H 'Host: query.example.org' http://192.168.10.20:8080/versions.json
   ```

4. Request both public HTTPS names through Cloudflare. Verify the returned
   domain/endpoint discovery, JSON media type, and redirects that contain
   neither `http://` nor a private address or port.
5. Test an uncached or authorization-bearing request and inspect origin logs:
   the client address must be the caller, not Cloudflare or HAProxy. Send a
   deliberately forged `X-Forwarded-For`; it must not replace that identity.
6. Test token-only data without a token (401), with a valid token (success),
   and after revocation (401). Do not put token secrets into URLs or logs.
7. Make repeated anonymous public requests to the same complete URL and confirm
   Cloudflare cache behavior. Change a search parameter and verify distinct
   results. An authorization-bearing request must bypass the edge cache.
8. On a disposable deployment, stop the origin and check HAProxy-generated
   failures through a controlled LAN test route for JSON/no-store behavior;
   separately check the public Cloudflare error response.

## Primary references

- [OPNsense HAProxy model and supported modes](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/models/OPNsense/HAProxy/HAProxy.xml)
- [OPNsense public-service form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogFrontend.xml)
- [OPNsense backend form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogBackend.xml)
- [OPNsense health-monitor form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogHealthcheck.xml)
- [OPNsense error-message form](https://github.com/opnsense/plugins/blob/master/net/haproxy/src/opnsense/mvc/app/controllers/OPNsense/HAProxy/forms/dialogErrorfile.xml)
- [HAProxy 3.2 configuration manual](https://docs.haproxy.org/3.2/configuration.html)
- [nginx virtual-host selection](https://nginx.org/en/docs/http/request_processing.html)
- [nginx real-IP module](https://nginx.org/en/docs/http/ngx_http_realip_module.html)
- [Cloudflare origin TLS validation](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
- [Cloudflare request headers](https://developers.cloudflare.com/fundamentals/reference/http-headers/)
- [Cloudflare published IP ranges](https://www.cloudflare.com/ips/)
