# Dedicated MCP domain

Deploy MCP as its own service on an operator-configured domain. Clients connect
to the domain root, for example **`https://mcp.example.org/`**. One protocol
endpoint covers every supported upstream API version; tools select those
versions through their arguments.

The installable **`getbible-mcp==2.0.1` PyPI package** owns the protocol, tools,
resources, prompts and API contracts. This engine owns the domain, Python
runtime, ASGI host, systemd lifecycle, local origin routing and nginx
configuration. Query and search remain separate services on their own domains.

## Deploy and maintain

Publish and verify the pinned MCP wheel on PyPI before deploying the service
or building its production image. Production deployments install the released
package; they do not install MCP from Git or another checkout.

Create the dedicated domain:

```bash
sudo getbible deploy mcp --domain mcp.example.org --python 3.12
```

Configure the MCP client with `https://mcp.example.org/`. The root path speaks
MCP directly, without version folders or an additional path suffix. A normal
browser request is not a protocol check: an MCP client initializes the session
and negotiates capabilities before listing or calling tools.

Manage the domain's service:

```bash
sudo getbible mcp status mcp.example.org
sudo getbible mcp configure mcp.example.org --python 3.12
sudo getbible mcp update mcp.example.org
sudo getbible mcp rollback mcp.example.org
```

The Deploy menu offers **MCP service at its dedicated domain root**. The domain's
MCP menu provides configuration, updates, rollback and its service journal.
Hostname, publication state and TLS belong to this dedicated domain. Package
updates retain its configured identity and upstream settings.

Deployment accepts `--access open|metered|token`, `--python`, `--origin`,
`--env-file` and the normal `--staged` or `--live` selection. Omitting the
publication flag uses `DEFAULT_DEPLOY_MODE`. A staged MCP domain remains staged
through updates; use the standard domain go-live action when it is ready for
public traffic. TLS ownership follows the engine's existing managed or external
TLS configuration. See [staged domains and go-live](NEW_SERVER.md).

To stop serving MCP and remove its managed domain, use the normal domain action:

```bash
sudo getbible remove mcp.example.org
```

## Local upstream routing

The default upstream service names are the official GetBible domains. Requests
connect to the configured local nginx origin, preserving each upstream's Host
header and public source URL. The service never connects to public Bible APIs.
External TLS deployments default to the configured local HTTP origin port;
native managed TLS defaults to `https://127.0.0.1:443` with each upstream's real
TLS server name and certificate verification. `--origin` overrides the local
address when required.

Use an existing absolute environment file with `--env-file` when this
installation uses different upstream domain names. For example:

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

These names must identify domains served by that local nginx origin. Missing
or private upstream data retains its normal HTTP failure; MCP does not bypass
source-domain access controls. This integration targets public source domains.
Source-domain metering records local service calls separately from callers of
the MCP domain. Bearer tokens are never forwarded across domains.

The environment file is authoritative service configuration and remains
independent of package releases. The library and host validate its settings
before starting a candidate.

## Updates, readiness and rollback

Each update builds an isolated release, starts an ASGI candidate on its own
Unix socket, checks readiness, tests/reloads nginx, then promotes the candidate.
Previous nginx workers keep their backend until their requests drain. Retained
releases support rollback.

The root MCP endpoint follows the dedicated domain's access policy, disables
proxy caching and buffering, and accepts protocol POST. The service runs with
a 256-MiB memory ceiling; aggregate planning reserves both serving and candidate
memory during updates.

## Traffic reporting

The dashboard's **MCP traffic** view keeps MCP service traffic distinct from
query and search API traffic. Filter by domain and time to inspect requests,
status, latency and errors, with protocol method, tool, client name/version,
user-agent and upstream service/API-version/operation details when available.
Client names and versions come from metadata supplied by the client.

The collector joins protocol metadata to the nginx request by request ID,
counting that origin request once. Requests rejected before they reach the
MCP process, malformed requests and robot traffic still belong to the MCP
domain's reporting. Protocol and tool failures remain visible even when their
HTTP response status is 200.

Reporting excludes raw tool arguments, request bodies and credentials. It may
retain safe token identifiers and authentication state. Existing telemetry
history is preserved.

## Docker and package validation

Docker images bundle the pinned Python packages as wheels at image-build time.
Domain deployment, service updates and container startup use those bundles
without fetching packages or compiling code. A new image applies the normal
domain transaction after restoring saved service state.

Before the package is published, tests may install an explicitly supplied
local release wheel:

```bash
GB_TEST_MCP_WHEEL=/absolute/path/getbible_mcp-2.0.1-py3-none-any.whl tests/run.sh
```

This test-only option does not change production requirements.
