# Access modes, tokens and limits

Every endpoint is in one of three modes, changeable at any time
(`getbible.sh access DOMAIN MODE` or the endpoint menu):

| Mode | Anonymous callers | Token holders |
| --- | --- | --- |
| `open` | unlimited | unlimited |
| `metered` (default) | a budget per client address | unlimited |
| `token` | `401` | unlimited |

## Budgets

Defaults for new endpoints (Settings > Defaults) and per endpoint
(`getbible.sh limits DOMAIN --rate N --burst N --hour N --day N --conn N`):

| Setting | Default | Enforced as |
| --- | --- | --- |
| requests per second | 50 | exact rate, `burst` extra requests allowed above it |
| burst | 250 | |
| per hour | 10 000 | token bucket refilling at the hourly rate, capacity a quarter of the quota |
| per day | 100 000 | token bucket refilling at the daily rate, capacity a quarter of the quota |
| concurrent connections | 100 | exact |

A client under its budget is never touched. Over it, nginx answers `429` as
a problem document with `Retry-After`. Budgets key on the client address
(the real one behind Cloudflare, see `CLOUDFLARE.md`); a valid bearer token
switches the key off entirely, which is how token holders are exempt.

## Tokens

Tokens are random 256-bit values rendered as lowercase base32 (`gb...`, 54
characters). They live in `/etc/getbible/endpoints/<domain>/tokens.json`
(root only) with an id, a label, created, optional expiry and revoked
timestamps. nginx gets a rendered map, `getbible/tokens/<slug>.map`, keyed
by `"<domain> Bearer <token>"`, so a token is valid only on the endpoint
that issued it and its id (never the secret) appears in logs and analytics.

```sh
getbible.sh token DOMAIN add "Mobile app"            # prints the token once
getbible.sh token DOMAIN add "Partner" --expires 2027-01-01
getbible.sh token DOMAIN list
getbible.sh token DOMAIN revoke tk_1a2b3c4d
```

Clients send `Authorization: Bearer <token>`. Tokens are never accepted in
the URL. CORS preflights, the documentation page and the health routes are
always open, so browsers can reach the `401`.
