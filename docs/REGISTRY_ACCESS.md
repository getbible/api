# Pull the private production image

Authenticate Docker to `ghcr.io` once on each production host. Later pulls reuse
that login while its token remains valid. Use `ghcr.io/getbible/api:latest` to
follow published updates; pulling an image does not replace a running container
until you run Compose again.

## 1. Grant read access and create the token

Use a dedicated GitHub machine account for deployments, or an existing account
with access to the package. A package administrator grants that account **Read**
under **getbible organization > Packages > api > Package settings > Manage access**.
Access may instead be inherited from the linked repository. For a machine
account, prefer explicit package access so it needs no source-repository access.
See [GitHub package permissions](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).

Sign in as that account, then:

1. Open **Settings > Developer settings > Personal access tokens > Tokens
   (classic) > Generate new token (classic)**, or use the
   [classic token creation page](https://github.com/settings/tokens/new?scopes=read:packages).
2. Give the token a recognizable host-specific name and an expiration allowed
   by your organization. Use a separate token for each production host.
3. Select **`read:packages` only** and generate the token. Keep it in your password
   manager for the login below.

GHCR currently requires a **classic** personal access token for this Docker
login. Repository SSH deploy keys and fine-grained tokens do not provide this
registry login. Pulling needs neither `repo`, `write:packages` nor
`delete:packages`. The token cannot grant access that its account lacks.
See [GitHub's registry authentication instructions](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-with-a-personal-access-token-classic)
and [token creation and organization policy](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-personal-access-token-classic).

If the organization uses SSO, choose **Configure SSO > Authorize** beside this
token. You may first need to sign in through the organization's identity provider.
Organization token restrictions and any applicable IP allowlist must also permit
this host. See [authorizing a token for SSO](https://docs.github.com/enterprise-cloud%40latest/authentication/authenticating-with-single-sign-on/authorizing-a-personal-access-token-for-use-with-single-sign-on).

## 2. Log in once on the Docker host

Run this in Bash as the host user who runs Compose. If you normally use
`sudo docker compose`, use `sudo docker` throughout the examples below.

```bash
(
    set +x
    set -e
    read -r -p 'GitHub username: ' GETBIBLE_PULL_USER || exit 1
    read -r -s -p 'Package read token: ' GETBIBLE_PULL_TOKEN || exit 1
    printf '\n'
    printf '%s' "$GETBIBLE_PULL_TOKEN" |
        docker login ghcr.io --username "$GETBIBLE_PULL_USER" --password-stdin
    unset GETBIBLE_PULL_TOKEN GETBIBLE_PULL_USER
    docker pull ghcr.io/getbible/api:latest
)
```

Expect `Login Succeeded`, followed by a successful pull. The token is entered
without echo, passed through stdin and discarded from the shell when the
subshell exits. Never put it in an application `.env`, Compose file, image,
command-line password argument or log.

Docker keeps credentials in the invoking user's configured helper or
`~/.docker/config.json` (`DOCKER_CONFIG` can override this). The file fallback is
encoded, **not encrypted**. Use owner-only directory/file permissions
(`0700`/`0600`), protect backups, and preserve this storage across maintenance.
An optional headless helper such as `pass` must remain usable by that Docker
user. Standard Docker authentication is sufficient. See [Docker login and credential storage](https://docs.docker.com/reference/cli/docker/login/).

## 3. Deploy and reuse the login

For a **new installation**, you can optionally extract both deployment files
directly from the image pulled above. This requires only the package read token;
no source-repository authentication is involved. Run from the parent directory
where you want to create `getbible-deployment`:

```bash
(
    set -eu
    umask 077
    mkdir getbible-deployment
    cd getbible-deployment
    GETBIBLE_TEMPLATE_CONTAINER=
    trap 'if [ -n "$GETBIBLE_TEMPLATE_CONTAINER" ]; then docker rm "$GETBIBLE_TEMPLATE_CONTAINER" >/dev/null; fi' EXIT
    GETBIBLE_TEMPLATE_CONTAINER="$(docker create ghcr.io/getbible/api:latest)"
    docker cp "$GETBIBLE_TEMPLATE_CONTAINER:/usr/share/getbible/api/compose.yaml" ./compose.yaml
    docker cp "$GETBIBLE_TEMPLATE_CONTAINER:/usr/share/getbible/api/.env.example" ./.env
    sed -i 's/^GETBIBLE_IMAGE_TAG=.*/GETBIBLE_IMAGE_TAG=latest/' .env
)
```

The command stops if `getbible-deployment` already exists, preserving existing
operator configuration. The temporary container is created **without starting
it**, used only to copy these files, and removed on exit. See Docker's
[create](https://docs.docker.com/reference/cli/docker/container/create/) and
[copy](https://docs.docker.com/reference/cli/docker/container/cp/) commands.
Enter the new directory and edit `.env` for your installation before starting
the API; follow [Docker configuration](DOCKER.md#3-set-the-installation-settings).

Alternatively, keep the workstation download approach:

From an authenticated workstation, download [compose.yaml](../compose.yaml)
and [.env.example](../.env.example) for the published release. Copy them to your
host's deployment directory, name the settings file `.env`, and complete the
[Docker configuration](DOCKER.md#3-set-the-installation-settings). No Git
checkout or repository-read token is required on the production host.

Set this in `.env`:

```dotenv
GETBIBLE_IMAGE_REPOSITORY=ghcr.io/getbible/api
GETBIBLE_IMAGE_TAG=latest
```

From that directory, pull the image, wait for a healthy container, and explicitly
apply its application updates to configured domains:

```sh
(
    set -e
    docker compose config --quiet
    docker compose pull getbible
    docker compose up -d --wait getbible
    docker compose exec --user root getbible getbible update
    docker compose ps
)
```

Any failed step stops the sequence. [Compose `--wait`](https://docs.docker.com/reference/cli/docker/compose/up/)
waits for container health before the explicit update runs. Image replacement
restores the retained runtime generations; `getbible update` then applies the
new application code and templates. Ordinary restarts continue to restore
saved deployments without redeploying them. See [updating and recovery](UPDATING.md#docker-image-updates).

Saved configuration and data remain in the persistent mounts. No repeated
login is needed unless credentials expire, are revoked, lose access, or their
local storage is removed. The release workflow publishes `latest` after merged
changes pass its checks. A new version in `VERSION`, such as `2.0.0`, also
publishes that numbered image without changing the production pull command.

Before a token expires, create a replacement with the same read scope, authorize
SSO if required, and repeat login and `docker pull` with it. After that succeeds,
delete the old token in GitHub. Replacing registry credentials does not restart
the running API container.

## Troubleshooting

| Result | Check |
| --- | --- |
| `unauthorized`, `denied` or HTTP 403 | Correct GitHub username; classic token with `read:packages`; account has package Read; token has not expired or been revoked; SSO and organization policy allow access. A successful login alone does not prove package access. |
| Login succeeds, Compose cannot pull | Login and Compose must use the same host user, `sudo` choice and Docker configuration/credential helper. |
| `manifest unknown` or `not found` after authentication | Check the image name and published tag in the package. A passing pull-request workflow does not publish an image; wait for the merged release workflow to finish. |
| Old image or runtime code remains active | Check `.env` uses `latest`, then run the complete update sequence above, including its explicit `getbible update`. |
