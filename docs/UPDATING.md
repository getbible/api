# Updating

```sh
cd /opt/getbible/api
sudo git pull --ff-only
sudo ./getbible.sh update          # or: menu > Update all endpoints
```

Update re-renders every endpoint from the current templates and code:

1. the log rotation configuration and timer;
2. for every endpoint: users, directories, sync units, documentation page,
   nginx files (staged, compared with what is installed, backed up,
   installed, `nginx -t`, reloaded once), and for runtime endpoints a new
   release when the code, requirements or gunicorn template changed, then a
   restart behind the readiness gate with automatic rollback;
3. Cloudflare address ranges when a proxied domain exists;
4. a Telegram summary.

Running it twice changes nothing. A file that was edited by hand on the
server is detected through the ledger of installed hashes
(`/var/lib/getbible/ledger`): interactively you see the diff and choose,
non-interactively (`--yes`) it is kept and reported. Backups of every
replaced file are under `/var/backups/getbible/`.

The menu's "git pull first, then update" refuses a checkout with local
modifications.

## Rolling back

- nginx: the previous backup set restores the files (`cp` them back, then
  `nginx -t` and `systemctl reload nginx`); the update itself restores them
  automatically when `nginx -t` fails.
- runtime: `ln -sfn <previous release> /opt/getbible/<kind>/current` and
  `systemctl restart getbible-<kind>`; the update does this automatically
  when a new release fails its readiness check.
- static: `ln -sfn releases/<version>/<previous> /srv/getbible/<domain>/<version>`
  as the sync user; the previous release is always kept.
