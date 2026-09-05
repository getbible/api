# getBible API

One script that deploys and maintains every public getBible API endpoint on a
server, securely and at high volume:

- **static endpoints**: versioned trees of JSON, checksum and text files,
  synchronised from git repositories by isolated users and served by nginx;
- **runtime endpoints**: the `query` (references) and `search` services built
  on the getBible librarian, each in its own sandboxed service behind nginx.

See `docs/INSTALL.md` to get started and `docs/` for everything else.

```sh
sudo git clone https://github.com/getbible/api.git /opt/getbible/api
cd /opt/getbible/api
sudo ./getbible.sh
```
