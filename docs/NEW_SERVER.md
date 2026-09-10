# Set up a new server and publish its domains

The host preparation and certificate instructions here describe native,
managed-TLS deployment. To pull the prepared system container, start with
[DOCKER.md](DOCKER.md), then use the same endpoint/key/menu workflow inside it
through `docker compose exec --user root getbible getbible`. External TLS and
public route checks are covered in [OPNSENSE_HAPROXY.md](OPNSENSE_HAPROXY.md).
The Docker host does not need the manager repository's deploy key; private
image pulls use a package token, while endpoint data keeps its separate SSH
deploy keys.

Start with a fresh host, install the manager, and create each domain through
its deployment workflow. A **staged** domain installs its services, data,
nginx configuration and documentation so they can be checked before public
launch. Go-live obtains the certificate and publishes the shared hostname.
Normal updates, certificate renewal and runtime generation rollback remain
available after launch.

## 1. Prepare the host

Set up root's deploy key for the manager repository and its SSH configuration
as in [INSTALL.md](INSTALL.md#1-clone), then:

```sh
sudo git clone git@github.com:getbible/api.git /opt/getbible/api
cd /opt/getbible/api
sudo ./getbible.sh install-deps
sudo ./getbible.sh
```

The menu's System > Check this host reports installed dependencies. Configure
these Settings before deploying:

- **Telegram notifications**: the bot token and chat id for deployment and
  maintenance messages. Each message identifies this server.
- **Cloudflare API token**, if Cloudflare should manage DNS or validate
  certificates. Enter it through the dialog so it is verified and certbot's
  DNS-01 configuration is written. Cloudflare management is optional.
- **Let's Encrypt contact email**.
- **Public addresses used for DNS records**: the server's public IPv4 and
  IPv6 addresses. Check the go-live plan before publishing them.
- **New domains: stage them** to make staged deployment the default. Each
  deployment walkthrough still lets you choose staged or live.
- **Certificate validation**: the default is HTTP-01 through nginx and needs
  no Cloudflare account or token. Automatic selects DNS-01 for managed
  Cloudflare domains when its token and plugin are available. DNS-01 is
  optional and can issue a certificate before public DNS points here.

## 2. Deploy static endpoints and register their keys

Choose Deploy a new domain > Static, enter the hostname, and choose **Stage
it**. The domain shares one sync system user, nginx vhost and certificate.
Every endpoint has its **own repository and deploy key**. For example, `v1`
and `v2` can use unrelated repositories on GitHub under one hostname.

The walkthrough displays the first endpoint's public key. Register it on
that endpoint's repository as a read-only deploy key. Adding another endpoint
shows another key for its repository. Use the domain's deploy-key menu to
select an endpoint, show its key, test access and sync. Repository URLs keep
their normal hostnames, such as `git@github.com:owner/repo.git`; no host aliases
are needed. Root's manager key is separate from every endpoint key.

```sh
sudo ./getbible.sh deploy static --domain api.getbible.net --version v1 --repo git@github.com:org/bible-v1.git --ref main --staged --yes
sudo ./getbible.sh deploy-key api.getbible.net v1
# Register this key on org/bible-v1 as read-only.
sudo ./getbible.sh repo-access api.getbible.net v1
sudo ./getbible.sh sync api.getbible.net v1

sudo ./getbible.sh version add api.getbible.net v2 --repo git@github.com:org/bible-v2.git --ref main --yes
sudo ./getbible.sh deploy-key api.getbible.net v2
# Register this different key on org/bible-v2 as read-only.
sudo ./getbible.sh repo-access api.getbible.net v2
sudo ./getbible.sh sync api.getbible.net v2
```

Use `root` as the label when the domain serves a single endpoint without
version folders. See [STATIC_ENDPOINTS.md](STATIC_ENDPOINTS.md) for source
changes, schedules and key retention.

## 3. Deploy runtime domains and configure access

A runtime endpoint reads files published by a static endpoint, so sync the
required scripture version first. Choose Deploy a new domain > Runtime,
select query or search, and select the existing local data root containing
that version. Each runtime endpoint gets its own service, release generations,
socket and cache; it must pass readiness before nginx routes requests to it.

```sh
sudo ./getbible.sh deploy runtime --domain query.getbible.net --kind query --version v2 --repository /srv/getbible/api.getbible.net --staged --yes
```

Set the domain's access mode, limits and optional Cloudflare settings. Issue
bearer tokens through the Tokens menu where needed. Configure pages, OpenAPI
documents and icons through their menus; custom files are kept separately
from generated files and are preserved on ordinary updates.

The main menu and `status` show whether each domain is staged or live.
Applying configuration or updating a staged domain keeps it staged.

## 4. Verify and issue certificates

Domain > **Verify this server end to end**, or `verify DOMAIN`, checks the
published static endpoints or runtime readiness, rendered nginx configuration,
`nginx -t`, certificate and local HTTPS using the real hostname. Runtime
checks include `/readyz`. Staged self-signed certificates are identified in
the report; live certificates must pass trust and hostname checks.
Local HTTPS checks allow up to ten seconds for nginx's reloaded workers to
accept connections with the new certificate, keeping the same TLS validation
on every attempt.

From another machine, a staged domain can also be inspected with:

```sh
curl --insecure --resolve query.getbible.net:443:203.0.113.10 https://query.getbible.net/v2/kjv/John3:16
```

Each domain has one certificate shared by every endpoint. A fresh staged
domain uses a self-signed placeholder for local tests. To obtain its trusted
certificate with the default HTTP-01 method, point public DNS at this server
and allow port 80. nginx serves Certbot's challenge directory for the domain;
Go-live checks reachability before validation. A certificate request failure
leaves the domain staged. Resolve the reported issue before trying again.
A certificate already issued for this domain is reused when adding endpoints.

For optional Cloudflare DNS-01, Domain > Certificate > **Issue a Let's Encrypt
certificate now** can obtain the certificate while the domain remains staged
and before DNS points here. Request it explicitly with:

```sh
sudo ./getbible.sh cert query.getbible.net issue --method dns-cloudflare
```

## 5. Go live

Choose Main menu > **Go live**, or Domain > **Go live**. Review the certificate
method and the addresses in the plan. The operation proceeds in this order:

1. Obtain the certificate if needed. Failure leaves the domain staged.
2. Apply HTTPS with the real certificate, validate nginx, reload it, and
   verify local readiness and HTTPS.
3. For a Cloudflare-managed domain, publish its A/AAAA records and configured
   proxy rules. Otherwise, DNS remains under your control.
4. Verify that the public hostname reaches this server using a fresh challenge
   marker and a trusted HTTPS health request. Checks retry for up to 60 seconds.
5. Report success only after verification. A propagation timeout reports the
   incomplete step while the service keeps serving. Correct the cause and run
   `verify DOMAIN`; for a Cloudflare error, apply its settings before verifying.

```sh
sudo ./getbible.sh go-live query.getbible.net --yes
sudo ./getbible.sh verify query.getbible.net
sudo ./getbible.sh status query.getbible.net
```

The verification wait can be adjusted for deployment checks:

```sh
sudo env GOLIVE_VERIFY_TIMEOUT=300 GOLIVE_VERIFY_INTERVAL=5 ./getbible.sh go-live query.getbible.net --yes
```

Verification observes this server's resolver and public route. If the host
cannot reach its own public address, check reachability from another machine.
Publish and verify each domain in turn.

## Maintain the installed domains

Use `self-update` to fetch the manager checkout, then `update DOMAIN` to apply
its code and configuration to a domain. Runtime redeployment, dependency
updates and rollback use retained deployment generations and readiness checks.
Static timers keep publishing repository changes with each endpoint's own key.
`install-deps` enables `certbot.timer`; Certbot renews each domain certificate
automatically using its recorded validation method. Its deploy hook validates
nginx and reloads it after successful renewal. `doctor` reports the timer and
renewal configuration, and normal domain updates maintain the deploy hook.

`stage DOMAIN` suspends automatic public DNS changes for subsequent applies
while retaining the domain's current services, certificate and data. It does
not rewrite DNS itself. Use the usual go-live workflow to publish it again.
See [UPDATING.md](UPDATING.md) for updates, recovery and operational checks.
