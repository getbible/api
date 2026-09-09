# Updating and recovery

## Update the manager script

When improvements are published, update the manager's checkout with one
command:

```sh
cd /opt/getbible/api
sudo ./getbible.sh self-update
```

The menu offers the same as **Update manager script** and exits after a
successful update. `self-update` fetches the checked-out branch's upstream
over the clone's own remote, using root's deploy key from `/root/.ssh/config`
(see [INSTALL.md](INSTALL.md#1-clone)), and advances the checkout by
fast-forward only. It updates the whole repository (script, libraries,
templates); the next invocation runs the updated code. It does not apply
configuration, install helpers, restart services or redeploy hosted domains,
and takes no domain argument. The management lock keeps other manager
commands out while it runs.

The update stops, changing nothing, if git is missing, the installation is
not a Git checkout, the checkout has local modifications or untracked files,
HEAD is detached, the branch has no upstream, or a fast-forward is not
possible; so do authentication and network failures. Resolve the reported
problem and run it again: the updater never discards local changes or merges
divergent history, and `--yes` does not bypass these checks. `sudo
./getbible.sh self-update --dry-run` reports what would be fetched without
contacting the remote.

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

## Maintenance checks

After updating the manager checkout, run `doctor` and the per-domain `update`
commands above. Each endpoint keeps its selected managed Python version on
ordinary updates. Runtime updates use the candidate, readiness, routing and
rollback process described above; static updates preserve published releases
and endpoint keys while applying the current configuration.

Before updating a token-only endpoint behind Cloudflare, grant the connector
Cache Purge permission. The update disables shared caching and purges that
hostname's previously public content before activation. Missing permission or
a failed purge aborts the protected transition. See [CLOUDFLARE.md](CLOUDFLARE.md).

### Static endpoint deploy keys

Static deploy keys are per endpoint and repository URL. Reapplying a domain
preserves each endpoint's key when its URL is unchanged. A repository URL
change selects a separate key, while branch and source-folder changes retain
the existing key. Register a new repository key as read-only before testing
access and syncing:

```sh
sudo ./getbible.sh deploy-key api.getbible.net v2
# Register the displayed public key on v2's repository as a read-only deploy key.
sudo ./getbible.sh repo-access api.getbible.net v2
sudo ./getbible.sh sync api.getbible.net v2
```

Other endpoints keep their own keys and published data. Use `root` as the
label for a domain without version folders. Root's manager-update key is
independent. See [STATIC_ENDPOINTS.md](STATIC_ENDPOINTS.md) for the complete
workflow with different repositories on one domain.

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
