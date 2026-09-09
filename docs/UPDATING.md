# Updating and recovery

## Update the manager script

Update the manager's source checkout with one command:

```sh
cd /opt/getbible/api
sudo ./getbible.sh self-update
```

The menu offers the same operation as **Update manager script** and exits
after a successful update. `self-update` fetches the checked-out branch's
configured upstream and advances the checkout by fast-forward only. It updates
the whole manager repository, including its script, libraries and templates;
the next invocation loads the updated code. It does not apply configuration,
install helpers, restart services or redeploy hosted domains, and accepts no
domain argument. Git uses the SSH release/deploy key configured during
[installation](INSTALL.md#1-clone). A manager lock prevents concurrent manager
commands during the source update.

The source update stops if Git is unavailable, the installation is not
a Git checkout, the checkout has local modifications (including untracked
files), HEAD is detached, the branch has no remote upstream, or a fast-forward
is not possible. Authentication and network failures also stop the operation.
Resolve the reported problem and retry; the updater does not discard local
changes or merge divergent history. `--yes` does not bypass these checks.

Use `sudo ./getbible.sh self-update --dry-run` to report the planned source
update without fetching or changing the checkout.

## Apply changes to hosted domains

When you choose to apply the checked-out templates and application changes,
run the separate domain update operation. To roll out to one domain first:

```sh
cd /opt/getbible/api
sudo ./getbible.sh doctor
sudo ./getbible.sh update query.getbible.net
sudo ./getbible.sh status query.getbible.net
sudo ./getbible.sh update
```

Plain `update DOMAIN` applies that domain (every endpoint of it) from the
current checkout without fetching; `update` processes all registered domains
and reports failures. After trying one domain, plain `update` applies the same
checkout to the rest without fetching newer commits. Manager mutations are
locked to prevent concurrent commands from interleaving configuration changes.
Staged domains (see `NEW_SERVER.md`) are updated like the others and stay
staged: an update never requests a certificate or changes DNS for them. An
update rewrites every generated page and OpenAPI document; the ones an
operator has taken over are left alone (`PAGES.md`).

## Choose the operation

| Operation | Result |
| --- | --- |
| `self-update` | Fetches the current branch's upstream and fast-forwards the clean manager checkout. The next invocation loads the updated code; hosted domains are not applied. |
| `update [DOMAIN]` | Applies checked-out templates, helpers, configuration, documentation and changed runtime code/dependency pins. Retains the selected exact Python patch. |
| `runtime DOMAIN update` | Rebuilds application dependencies and adopts the latest reviewed patch of each endpoint's selected Python family. `runtime DOMAIN v3 update` does it for one endpoint. |
| `runtime DOMAIN [vN] update --python 3.14` | Explicitly selects the catalog's current 3.14 patch and creates a new runtime release. An exact catalog patch is also accepted. |
| `runtime DOMAIN redeploy` | Starts a fresh deployment of every endpoint's current release and settings, rebuilding code only if its inputs changed. |
| `runtime DOMAIN [vN] set WORKERS 4` | Validates the endpoint's setting and activates a new generation; the running process receives the updated configuration. |
| `runtime DOMAIN [vN] rollback` | Activates the endpoint's retained previous code, interpreter and settings, preserving the domain's current access mode, quotas and tokens. |
| `version add DOMAIN v3` | Adds a version to a runtime domain as its own service (see `RUNTIME_ENDPOINTS.md`); `version default DOMAIN v3` makes it answer `/` and the short forms. |
| `sync DOMAIN v2` | Fetches and publishes the selected trusted static endpoint, then atomically changes its live symlink when needed. |

See `runtime versions` for the reviewed interpreter catalog. New upstream
Python releases become eligible after a repository change updates
`src/python/distributions.lock`; deployment never queries an unpinned latest
interpreter feed. Application dependency changes belong in the kind's pinned
`requirements.txt`. Built releases retain Python provenance and `packages.lock`.
Host Python updates cannot replace managed runtime Python or its standard
library. Kernel, glibc, systemd and nginx updates remain host maintenance.

## How an update preserves service

Runtime releases build beside the live release, for every endpoint of the
domain that needs a change. Each candidate gets a separate environment,
systemd service and socket. It must serve real scripture through `/readyz`;
search also passes its search probe before traffic changes. nginx
configuration is backed up, validated with `nginx -t`, and gracefully reloaded
once for all of them.
The old backend stays alive until the recorded pre-reload nginx workers exit;
PID start times guard against PID reuse. Retirement runs independently of the
CLI. Allow temporary memory for both generations and their warm-up work.

Preparation failures leave the old runtime serving. Activation failures restore
the prior routing and deployment state; a failed routing recovery retains
processes and reports the failure for inspection. nginx is never restarted by
the deployment pipeline. Static data rotation needs neither a runtime restart
nor an nginx reload: an interrupted export is never published. Upstream content
is copied as committed, without a second JSON or checksum validation pass.

Unchanged code and configuration reuse their existing deployment. Hand-edited
managed files are detected against `/var/lib/getbible/ledger`: an interactive
update asks before replacing them; `--yes` keeps and reports them. A declined
nginx route change aborts the deployment and restores its prior routing, so
review and reconcile local edits before retrying. Backup sets are retained
under `/var/backups/getbible/`.

## Migrate an existing installation

### Existing HTTPS Git checkout

Prepare and verify the root-owned release/deploy key as described in
[INSTALL.md](INSTALL.md#1-clone), then change the repository URL and persist
the key selection. These commands assume the remote is named `origin`:

```sh
cd /opt/getbible/api
sudo git remote set-url origin git@github.com:getbible/api.git
sudo git config core.sshCommand 'ssh -i /root/.ssh/getbible-api -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes'
sudo git status --short
sudo git branch -vv
sudo git pull --ff-only
```

The first manual pull installs the new `self-update` command on older
checkouts. Afterwards, use that command or **Update manager script** in the
menu. This migration updates only the source checkout. Keep local source
changes out of the production checkout; reconcile any edits before pulling. If the
branch has no upstream, configure it to track the intended remote branch
before updating (for example, `sudo git branch --set-upstream-to=origin/main
main` when `main` is your deployment branch). Existing clones with a
different remote name should configure that remote instead.

### Archive or copied installation without `.git`

Keep the existing directory as a backup and clone into a separate empty
directory, for example `/opt/getbible/api-git`, using the SSH clone command in
[INSTALL.md](INSTALL.md#1-clone) with that destination. Use `self-update` from
the new checkout for future manager updates. Use this new path for other
commands and any operator-created shortcuts or scheduled commands. Do not
copy the old source tree over the new
clone, or store private keys in it.

The manager's registered domains and credentials remain in `/etc/getbible`,
state remains in `/var/lib/getbible`, and static/runtime data and releases stay
in their existing paths. Preserve these directories and any custom external
data paths; cloning the manager does not replace them. If you kept custom
assets or data inside the old source directory, keep that directory until
those files and any configuration references have been migrated separately.

### Managed domains

To apply changes to hosted domains after updating the manager, separately run
`doctor` and the per-domain `update` commands above. Existing
single-service runtime installations are captured as rollback generations;
the first successful update moves them to owned Python and isolated deployment
generations. An existing exact managed Python version remains selected on
ordinary updates. Token-map permissions and per-request expiry maps migrate
with the nginx configuration.

A runtime domain recorded before endpoints had their own records (a `VERSION`
key and the service settings in `endpoint.conf`) gets its endpoint record
(`versions/<version>.conf`, `LAYOUT=legacy`) the first time the tool looks at
it: the settings are copied into the record and every path, unit and socket
stays where it is, so nothing running is moved or restarted by the migration
itself. The next apply proceeds as any other. Versions added afterwards get
their own paths (`/opt/getbible/<kind>/<version>/`). Static domains gain a
page per endpoint and `versions.json` on their first update; nothing about
their data changes.

Before updating a token-only endpoint behind Cloudflare, grant the connector
Cache Purge permission. The update disables shared caching and purges that
hostname's previously public content before activation. Missing permission or
a failed purge aborts the protected transition. See [CLOUDFLARE.md](CLOUDFLARE.md).

## Recovery and operational checks

```sh
sudo ./getbible.sh status query.getbible.net
sudo ./getbible.sh logs query.getbible.net journal v2 --lines 100
sudo ./getbible.sh runtime query.getbible.net v2 rollback
sudo nginx -t
```

Use the rollback command instead of manually changing `current` or restarting
a historical unit name: code, settings, service names and sockets must agree.
If automatic routing restoration reports failure, inspect the nginx error and
backup sets before retrying; retain the old generation and interpreter files.
Manual nginx recovery must validate configuration before `systemctl reload
nginx`. Static data recovery can republish a corrected source commit with
`sync DOMAIN v2 --force`; retained releases also permit an operator-controlled
atomic symlink restore while holding that endpoint's sync lock.

CI exercises supported Python families, real nginx/Gunicorn, actual systemd
service users, upgrades, failure recovery and a request-load smoke test. These
checks do not establish an enterprise SLA. The source repositories remain authoritative; production
updates do not run corpus validation or introduce additional monitoring/load
tests. Maintain the host independently of the application.
