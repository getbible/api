# Rebuilding on a new server without downtime

The API keeps serving from the old server while the new one is prepared.
Every endpoint is deployed **staged**: the large parts (managed Python, the
runtime releases, the git clones and synchronised data, sync users and timers,
nginx, tokens, limits, documentation pages) are installed and verified, but no
certificate is requested and DNS is not changed. When everything is in place,
each domain goes live from the menu, one at a time. The old server is never
touched.

| Step | Old server | New server |
| --- | --- | --- |
| 1 | serving | clone, `install-deps`, Telegram, Cloudflare token, contact email, public addresses |
| 2 | serving | Settings > New endpoints: **stage** |
| 3 | serving | deploy every static endpoint ("Stage it"), sync its data, then the runtime endpoints; carry tokens across |
| 4 | serving | Verify each endpoint; issue certificates in advance (DNS-01) |
| 5 | serving for cached DNS | **Go live**, one domain at a time |
| 6 | retire | serving |

Everything below is done from `sudo ./getbible.sh` (the whiptail menu). The
command line forms are listed at the end for scripts.

## 1. Prepare the host

```sh
sudo git clone https://github.com/getbible/api.git /opt/getbible/api
cd /opt/getbible/api
sudo ./getbible.sh install-deps
sudo ./getbible.sh
```

`install-deps` installs nginx, certbot and, where the package exists, the
`python3-certbot-dns-cloudflare` plugin that makes certificates possible
before DNS changes. System > Check this host shows what was found.

Then, under Settings:

- **Telegram notifications**: the same bot token and chat id as the old
  server. Use the dialog rather than copying `telegram.conf`: the dialog
  records this server's host name, which prefixes every message, so the two
  servers stay distinguishable in the chat while both report.
- **Cloudflare API token**: the same scoped token as the old server, entered
  through the dialog even when reusing it: the dialog verifies the token and
  writes certbot's copy for DNS-01 renewals. The token must carry DNS:Edit
  for the zone; it is what DNS-01 validation and the go-live DNS switch use.
- **Let's Encrypt contact email**.
- **Public addresses used for DNS records**: the IPv4 and IPv6 addresses
  the go-live DNS switch writes. Left empty, the IPv4 is looked up through
  api.ipify.org and the IPv6 is the first global address on any interface,
  which is wrong on hosts with a management address; the go-live plan shows
  what will be used, so check it there too.
- **New endpoints: stage them**. Every deploy walkthrough still asks, but
  the default is now "Stage it", so nothing goes live by accident while the
  server is being built.
- **Certificate validation**: leave it on automatic. For a domain whose
  Cloudflare mode is `dns` or `proxied` it uses DNS-01 through the token
  whenever the plugin is present, and HTTP-01 otherwise. A domain whose DNS
  is on Cloudflare but is not managed here (mode `off`) can still choose
  `dns-cloudflare` when going live or issuing a certificate.

For zones not on Cloudflare, lower the TTL of the current records (to 300
seconds or so) at least one old TTL period before the switch, so that both
the switch and any rollback take effect quickly. Cloudflare-managed records
are written with automatic TTL.

## 2. Deploy every endpoint, staged

Deploy a new endpoint > Static or Runtime asks for the domain exactly as it
is served today (`api.getbible.net`, `query.getbible.net`, ...) and then
**Go live now?** Answer **Stage it**.

Order matters: a runtime endpoint reads its scripture files from a static
endpoint's data root and must pass readiness at deploy time, so it needs the
data to exist. Deploy the static endpoint first, add its deploy key to the
repository (the walkthrough shows it; Endpoint > Show the deploy key repeats
it), run **Sync now**, and confirm with Endpoint > Verify that the version is
published. Only then deploy the runtime endpoints. A runtime deploy that
failed readiness because the data was missing is completed later with
Endpoint > Re-apply configuration.

A staged deploy does everything except take over the public name:

- static: the sync user, deploy key, timers and nginx are installed and a
  placeholder certificate is created.
- runtime: managed Python and the release are built, the service starts and
  must pass readiness, nginx routes to it, a placeholder certificate is
  created.

Then set per endpoint whatever the old server has: access mode, limits,
Cloudflare mode, edge cache and origin pulls. On the old server,
`/etc/getbible/endpoints/<domain>/endpoint.conf` lists all of them (the
status page shows the Cloudflare mode, cache and origin pulls as well).
Setting the Cloudflare mode on a staged endpoint records it only; note that
the origin-pulls toggle is a zone-wide Cloudflare setting that takes effect
at once.

**Bearer tokens.** Copy `/etc/getbible/endpoints/<domain>/tokens.json` from
the old server (root only, mode 0600) and choose Endpoint > Re-apply
configuration: the nginx token maps are rendered from that file, so token
holders keep working after the switch without new tokens. Tokens issued on the
new server before the switch are fine too; just do not issue tokens on both
servers for the same domain.

The main-menu overview and `status` show every endpoint as `staged` or
`live`. Update all endpoints keeps staged endpoints staged.

## 3. Verify the new server

Endpoint > **Verify this server end to end** checks, for one domain, the
service (runtime readiness through its socket, or published static versions),
the rendered nginx site, `nginx -t`, the certificate in use, and HTTPS through
the local nginx with the real host name: `GET /`, `GET /healthz` and, for
runtime endpoints, `GET /readyz`. While staged, the placeholder certificate is
self-signed and the report says so.

From another machine, with the new server's address:

```sh
curl --insecure --resolve query.getbible.net:443:203.0.113.10 https://query.getbible.net/v2/kjv/John3:16
```

## 4. Certificates before the switch

Going live with a real certificate already present is instantaneous: no
client ever meets a connection without HTTPS. Three ways:

- **DNS-01 through Cloudflare** (zones on Cloudflare): Endpoint >
  Certificate > **Issue a Let's Encrypt certificate now**. Automatic
  validation picks `dns-cloudflare` for a Cloudflare-managed endpoint (choose
  it explicitly for one whose mode is `off`); certbot publishes a TXT record
  with the stored token and Let's Encrypt issues the certificate while DNS
  still points at the old server. The endpoint stays staged, now serving the
  real certificate. Renewals keep using DNS-01.
- **Copy the old server's certificates** (any zone): `rsync -a
  old:/etc/letsencrypt/ /etc/letsencrypt/` (archive, live and renewal
  directories together, as root). The manager reuses a certificate it finds.
  This only suits certificates this tool issued: check
  `/etc/letsencrypt/renewal/<domain>.conf` afterwards. `authenticator =
  webroot` with `/var/www/letsencrypt` renews through the challenge
  directory the new server serves too (attempts before the switch fail
  harmlessly); `authenticator = dns-cloudflare` renews through
  `/etc/getbible/certbot-cloudflare.ini`, which the Cloudflare token dialog
  writes. A lineage from another setup (`nginx`, `standalone`) would edit
  the rendered vhosts on renewal: reissue it instead. System > Check this
  host warns about both cases. Re-apply the endpoint afterwards.
- **HTTP-01 at go-live** (zones not on Cloudflare, nothing copied): change
  DNS yourself, confirm it (`dig +short api.example.org`, or the curl above
  without `--resolve`), then go live. Go live probes whether the name
  reaches this server and asks before trying when it does not; certbot then
  validates through the challenge directory. Clients with fresh DNS meet a
  few seconds without HTTPS while certbot runs.

Let's Encrypt limits failed validations to five per hostname per hour, and
identical certificates to five per week. Check reachability and the token's
scope before retrying rather than repeating go-live in a loop; the tool
never requests a certificate that already exists.

## 5. Go live, one domain at a time

Main menu > **Go live** lists the staged endpoints; Endpoint > **Go live**
does the same for one. It asks for the validation method when a certificate
still has to be requested (automatic is right), shows the plan with the
addresses it will write, and confirms. Then, in order:

1. The certificate: reused when present, otherwise requested. If this fails
   nothing has changed and the endpoint stays staged; fix the cause and
   choose Go live again.
2. The endpoint is marked live and applied: nginx renders HTTPS with the real
   certificate, validates and reloads.
3. Cloudflare-managed domains (mode `dns` or `proxied`; the token must be
   stored): the A and AAAA records are pointed at this server and, when
   proxied, the API-safe rules, real-IP ranges and origin pulls are applied
   (the ranges and origin CA are fetched before the vhost is rendered). For
   other domains, DNS is left alone: change it yourself before going live.
4. Verification runs through the local nginx, and Telegram receives
   "Live: DOMAIN" with the certificate, the DNS outcome and whether the
   verification passed. The full report is in the dialog.

Do the next domain when the first looks right. The old server keeps
answering clients whose resolvers still cache the old address until the DNS
TTL passes; nothing on it changes. Once every domain is live and the TTL has
passed, retire the old server. Settings > New endpoints can go back to
"live" on the new server afterwards.

## Going back

Before go-live there is nothing to undo: the old server serves, the new one
waits. After go-live, first choose Endpoint > **Stage again** on the new
server (or `stage DOMAIN`): the endpoint keeps serving as it is, but no
later apply, update, token or limit change on the new server points DNS at
it again. Then point DNS back at the old server (Cloudflare dashboard, or
`cloudflare apply` on the old server) and it serves again. The new server
keeps its state and certificate for another attempt.

## Command line forms

Non-interactive runs need `--yes`; with it, go-live refuses an unpublished
static version and, with automatic validation, a name that does not seem to
reach this server. `--cert http` states that the name does reach it (for
hosts that cannot reach their own public address) and lets certbot decide.

```sh
sudo ./getbible.sh settings deploy-mode staged
sudo ./getbible.sh settings certbot-email you@example.org
sudo ./getbible.sh settings public-ipv4 203.0.113.10
sudo ./getbible.sh deploy static --domain api.getbible.net --version v2 --repo git@github.com:getbible/v2_scripture.git --staged --yes
sudo ./getbible.sh sync api.getbible.net v2
sudo ./getbible.sh deploy runtime --domain query.getbible.net --kind query --staged --yes
sudo ./getbible.sh cloudflare mode query.getbible.net proxied
sudo ./getbible.sh access query.getbible.net metered
sudo ./getbible.sh limits query.getbible.net --rate 50 --burst 250
sudo ./getbible.sh verify query.getbible.net
sudo ./getbible.sh cert query.getbible.net issue --method dns-cloudflare   # while staged
sudo ./getbible.sh go-live query.getbible.net --yes [--cert auto|http|dns-cloudflare]
sudo ./getbible.sh stage query.getbible.net                             # rolling back
sudo ./getbible.sh status
```
