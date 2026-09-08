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
| 1 | serving | clone, `install-deps`, Telegram, Cloudflare token, contact email |
| 2 | serving | Settings > New endpoints: **stage** |
| 3 | serving | deploy every endpoint ("Stage it"), sync data, carry tokens across |
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
  server (or copy `/etc/getbible/telegram.conf` across). From here on every
  step reports there.
- **Cloudflare API token**: the same scoped token as the old server, or copy
  `/etc/getbible/cloudflare.conf`. The token must carry DNS:Edit for the zone;
  it is what DNS-01 validation and the go-live DNS switch use.
- **Let's Encrypt contact email**.
- **New endpoints: stage them**. Every deploy walkthrough still asks, but
  the default is now "Stage it", so nothing goes live by accident while the
  server is being built.
- **Certificate validation**: leave it on automatic. For a domain whose
  Cloudflare mode is `dns` or `proxied` it uses DNS-01 through the token
  whenever the plugin is present, and HTTP-01 otherwise. A domain whose DNS
  is on Cloudflare but is not managed here (mode `off`) can still choose
  `dns-cloudflare` when going live or issuing a certificate.

## 2. Deploy every endpoint, staged

Deploy static endpoints first: runtime endpoints take their scripture files
from a static endpoint's data root. Deploy a new endpoint > Static or Runtime
asks for the domain exactly as it is served today (`api.getbible.net`,
`query.getbible.net`, ...) and then **Go live now?** Answer **Stage it**.

A staged deploy does everything except touch the public name:

- static: the sync user, deploy key, timers and nginx are installed and a
  placeholder certificate is created. Add the new deploy key to the
  repository (the walkthrough shows it; Endpoint > Show the deploy key
  repeats it) and run **Sync now** so the data is published on this server.
- runtime: managed Python and the release are built, the service starts and
  must pass readiness, nginx routes to it, a placeholder certificate is
  created.

Then set per endpoint whatever the old server has: access mode, limits,
Cloudflare mode and edge cache. `status DOMAIN` on the old server lists them.

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
  Certificates issued over HTTP-01 renew through `/var/www/letsencrypt`,
  which the new server serves as well; certificates issued over DNS-01 renew
  through `/etc/getbible/certbot-cloudflare.ini`, which storing the Cloudflare
  token under Settings writes (System > Check this host warns about renewals
  that lack it). Re-apply the endpoint afterwards.
- **HTTP-01 at go-live** (zones not on Cloudflare, nothing copied): change
  DNS yourself, then go live. Go-live first checks that the name reaches this
  server, then requests the certificate. Clients with fresh DNS meet a few
  seconds without HTTPS while certbot runs.

Let's Encrypt allows five identical certificates per week, so issue each
domain's certificate once rather than in a loop.

## 5. Go live, one domain at a time

Main menu > **Go live** lists the staged endpoints; Endpoint > **Go live**
does the same for one. It asks for the validation method (automatic is
right), shows the plan and confirms. Then, in order:

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
4. Verification runs and Telegram receives "Live: DOMAIN".

Do the next domain when the first looks right. The old server keeps
answering clients whose resolvers still cache the old address until the DNS
TTL passes; nothing on it changes. Once every domain is live and the TTL has
passed, retire the old server. Settings > New endpoints can go back to
"live" on the new server afterwards.

## Going back

Before go-live there is nothing to undo: the old server serves, the new one
waits. After go-live, point DNS back at the old server (Cloudflare dashboard,
or `cloudflare apply` on the old server) and it serves again; the new server
keeps its state for another attempt.

## Command line forms

```sh
sudo ./getbible.sh settings deploy-mode staged
sudo ./getbible.sh settings certbot-email you@example.org
sudo ./getbible.sh deploy static --domain api.getbible.net --version v2 --repo git@github.com:getbible/v2_scripture.git --staged
sudo ./getbible.sh deploy runtime --domain query.getbible.net --kind query --staged
sudo ./getbible.sh verify query.getbible.net
sudo ./getbible.sh cert query.getbible.net issue            # while staged, DNS-01 when available
sudo ./getbible.sh go-live query.getbible.net [--cert auto|http|dns-cloudflare]
sudo ./getbible.sh status
```
