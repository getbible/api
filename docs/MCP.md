# MCP endpoint

The optional MCP service attaches one **`/mcp`** endpoint to an existing API
domain. Its installable dependency, **`getbible-mcp==2.0.0` from PyPI**, owns
tools, resources, prompts and API contracts. The engine owns the Python
runtime, systemd lifecycle, origin routing and nginx configuration. Query and
search applications keep their existing WSGI workers and version endpoints.

**Release prerequisite:** publish and verify the `getbible-mcp` 2.0.0 wheel on
PyPI before enabling this integration or building its production image. This
engine change is a release candidate until that dependency is available.
Production deployments do not install MCP from Git or borrow another checkout.

After the package release, enable it on a domain already managed by this engine:

```bash
sudo getbible mcp enable api.example.org --python 3.12
sudo getbible mcp status api.example.org
sudo getbible mcp update api.example.org
sudo getbible mcp rollback api.example.org
sudo getbible mcp disable api.example.org
```

The main menu exposes the same actions under **MCP**. Enabling does not create a
domain, request a certificate or change its publication state. Clients connect
to `https://api.example.org/mcp`; upstream API version selection is a tool
argument, so separate MCP versions or `/v2/mcp` endpoints are unnecessary.

The default upstream service names are the official GetBible domains. Requests
connect to the configured local nginx origin, preserving each upstream's Host
header and public source URL. The service never connects to public Bible APIs.
External TLS deployments default to the configured local HTTP origin port;
native managed TLS defaults to `https://127.0.0.1:443` with each upstream's real
TLS server name and certificate verification. `--origin` overrides the local
address when required.
Configure an existing absolute environment file with `--env-file` when this
installation uses different domain names. For example:

```dotenv
GETBIBLE_API_V2_BASE=https://api.example.org/v2
GETBIBLE_API_V3_BASE=https://api.example.org/v3
GETBIBLE_QUERY_V2_BASE=https://query.example.org/v2
GETBIBLE_QUERY_V3_BASE=https://query.example.org/v3
GETBIBLE_SEARCH_V2_BASE=https://search.example.org/v2
GETBIBLE_SEARCH_V3_BASE=https://search.example.org/v3
GETBIBLE_DICTIONARIES_BASE=https://dictionaries.example.org/v1
GETBIBLE_COMMENTARIES_BASE=https://commentaries.example.org/v1
GETBIBLE_BOOKMARKS_BASE=https://bookmarks.example.org/v1
```

These names must resolve to domains served by that nginx origin. Missing or
private upstream data retains its normal HTTP failure; MCP does not bypass
source-domain access controls. This integration targets public source domains;
private source domains return their normal authorization failure. Source-domain
metering sees local service calls and remains separate from the MCP caller's
outer-domain authentication. Bearer tokens are never forwarded across domains.
The environment file is authoritative service
configuration and is preserved independently of package releases. Its settings
are validated by the library and host before the candidate starts.

Each update builds an isolated release, starts an ASGI candidate on its own
Unix socket, checks readiness, tests/reloads nginx, then promotes the candidate.
Previous nginx workers keep their backend until their requests drain. Retained
releases support rollback. The MCP route follows the selected domain's access
policy, disables proxy caching and buffering, and accepts protocol POST without
adding POST to unrelated static paths. The service runs with a 256-MiB memory
ceiling; aggregate planning reserves both serving and candidate memory.

Docker images bundle the pinned Python packages as wheels at image-build time.
Endpoint enable/update and container startup use those installed bundles without
fetching packages or compiling code. A new image applies the same normal domain
transaction after restoring saved service state.

Before publication, tests may install an explicitly supplied local release
wheel:

```bash
GB_TEST_MCP_WHEEL=/absolute/path/getbible_mcp-2.0.0-py3-none-any.whl tests/run.sh
```

This test-only option does not change production requirements.
