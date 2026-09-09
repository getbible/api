# Pages, OpenAPI documents, icons and versions.json

Besides its data, every domain publishes a few files that describe it. This
document says which files exist, where each one comes from, how to take one
over, and how nginx serves them.

## Vocabulary

- A **domain** is a host name: one nginx vhost, one certificate, one go-live.
  `api.getbible.net` and `query.getbible.net` are domains.
- An **endpoint** is one of the domain's version folders: `/v2/`, `/v3/`.
  Each endpoint of a static domain is its own tree synchronised from its own
  repository; each endpoint of a runtime domain is its own service. A domain
  set up without version folders serves a single endpoint at its root (the
  label `root`): domain and endpoint are then the same thing, and everything
  written below for `/vN/` applies to `/`.

## What a domain publishes

| Address | What | Sources |
| --- | --- | --- |
| `/` | the domain page: what the domain is and its endpoints (or, for a root endpoint, that endpoint's page) | generated, custom |
| `/vN/` | the endpoint's documentation page | generated, custom, repository (static only), none |
| `/vN/openapi.json` | the endpoint's OpenAPI document | generated (runtime only), repository (static only), custom, none |
| `/versions.json` | the endpoints whose OpenAPI document is present, mapped to that document (including a single root endpoint) | generated |
| `/version.json` | alias of `/versions.json`, serving the same generated file | generated |
| `/favicon.ico` | the favicon linked from every generated page | the repository's icon, the system favicon, the domain's own, none |
| `/img/…` | the logo at the top of every generated page, the icon at its foot, the touch icon and the link-preview image | the repository's icons, the system logo, the domain's own, none |
| `/openapi.json` | for a root endpoint its document; for a runtime domain with version folders the default endpoint's document, kept for clients that learnt the address before version folders existed | follows the endpoint |

Every one of these is public in every access mode (open, metered, token
only), is served by its own nginx location, and loads whatever file types the
endpoint allows for its data: an endpoint that serves only `json`, `sha` and
`txt` still has its HTML page. Pages carry the HTML security headers (a
locked CSP that allows inline styles and images from the domain itself);
documents carry the API headers with `Cache-Control: public, max-age=300`.

## Sources

**generated** is the default. The tool renders the page or document from its
templates (`src/docs-site/` for static pages, `src/apps/<kind>/` for runtime
pages and documents) and rewrites it on every apply and update, so it always
matches the configuration. A runtime endpoint generates its OpenAPI document;
a static endpoint cannot (the tool does not know the repository's contents),
so its default document source is the repository.

**custom** is yours. The file lives under `/var/www/getbible/<domain>/`
(`index.html` for the domain page, `<label>/index.html` and
`<label>/openapi.json` for an endpoint; for a root endpoint directly in the
domain's directory), never inside a repository checkout. Once taken over, the
tool records the source as `custom` and never rewrites the file again, on
apply, update or sync, until you hand it back to `generated`. Take a page or
document over in one of three ways:

- **Edit**: the tool copies the generated version into place (when nothing is
  there yet) and opens it in your editor (`$VISUAL`, `$EDITOR`, `nano` or
  `vi`), so you start from a complete page rather than a blank one.
- **From a file on this server**: the tool copies the file over the page or
  document. An OpenAPI document must be valid JSON; anything else is refused.
- **Custom** (command line): mark the file as yours without opening an editor.

**repository** applies to static endpoints: the page or document is a file
inside the version's folder of the repository (by default `index.html` and
`openapi.json`, any path you name). The sync exports these files by path
whatever the endpoint's file types, and nginx serves them straight from the
published tree, so they follow every sync. The tool reports whether the file
is present in the current release; a document that arrives with a later sync
is linked as soon as that sync finishes, because every sync unit ends by
refreshing the domain's generated files and `versions.json`.

**none** removes the address: it answers 404 like everything else the domain
does not serve.

The domain page has no `repository` or `none` source: a domain with version
folders always has a page at `/` (generated or yours) that lists them.

## Icons: the favicon and the logo

The repository ships the getBible icons in `img/`, and every domain publishes
them by default: on every apply the tool copies them from the checkout into
`/var/www/getbible/<domain>/` (`favicon.ico` and `img/`), so a new domain
serves them from its first deploy and `update` brings a changed set to every
domain.

| File in `img/` | Where it is used |
| --- | --- |
| `icon-96.png` | `/favicon.ico`, the icon browsers show in the tab; also the small icon at the foot of every generated page |
| `logo.png` | the logo at the top of every generated page |
| `icon-180.png` | `apple-touch-icon` (home screens, bookmarks) |
| `icon-230.png` | the large icon linked for shortcuts |
| `social.png` | the image link previews show (`og:image`) |

The favicon and the logo can each be replaced, for every domain or for one:

- **Settings > Icons** (`getbible.sh favicon FILE`, `getbible.sh logo FILE`)
  replaces the favicon (`.ico`, `.png`, `.svg` or `.gif`, served with the
  matching media type) or the logo (`.png`, `.jpg`, `.svg`, `.gif` or `.webp`)
  for every domain. The files are kept under `/etc/getbible/` (`favicon.ico`,
  `logo.EXT`) and published by Update all domains (the menu offers to do that
  at once). `default` returns to the repository's icon, `none` switches it
  off. `getbible.sh icons` shows both.
- **Domain > Pages and OpenAPI > Favicon / Logo** (`pages DOMAIN favicon
  FILE`, `pages DOMAIN logo FILE`) does the same for one domain, or serves
  none there.

A replaced favicon is linked on its own (the touch icon and the large icon
belong to the repository's set); a replaced logo is shown at the top and,
scaled down, at the foot of the pages. With the logo switched off the pages
show no images. Generated pages link only what the domain serves.

## Where to change these things

Every item is under **Domain > Pages and OpenAPI** in the menu. The screen
lists the domain page, every endpoint's page and document with its source and
whether the file is present, and the favicon; **Show all sources and files**
prints the same as `getbible.sh pages DOMAIN show`. Choosing an item offers
exactly the sources that apply to it. Changing anything applies the domain
(nginx is re-rendered so the right location exists, generated files are
rewritten).

Command line:

```sh
getbible.sh pages DOMAIN                                 # or: pages DOMAIN show
getbible.sh pages DOMAIN docs generated                  # the domain page
getbible.sh pages DOMAIN docs edit                       # take the domain page over in an editor
getbible.sh pages DOMAIN docs v2 from /root/v2-page.html # copy a file over the endpoint page
getbible.sh pages DOMAIN docs v2 repository docs/index.html
getbible.sh pages DOMAIN docs v2 none
getbible.sh pages DOMAIN openapi v2 repository api/openapi.json
getbible.sh pages DOMAIN openapi v2 from /root/openapi.json
getbible.sh pages DOMAIN openapi v2 generated             # runtime endpoints
getbible.sh pages DOMAIN favicon default|none|/root/icon.png
getbible.sh pages DOMAIN logo default|none|/root/logo.png
getbible.sh pages DOMAIN publish                          # rewrite the generated files only
getbible.sh icons                                         # the favicon and logo every domain serves by default
getbible.sh favicon /root/icon.ico                        # replace the favicon for every domain
getbible.sh favicon default|none
getbible.sh logo /root/logo.png                           # replace the logo for every domain
getbible.sh logo default|none
```

For a root endpoint the endpoint label is `root`: `pages DOMAIN docs root
repository docs/index.html`.

## How nginx serves them

Pages and documents are exact locations (`location = /v2/`,
`location = /v2/openapi.json`, `location = /`, `location = /versions.json`,
`location = /favicon.ico`), rendered only for sources other than `none`, with
`try_files` on the configured file and a fixed media type; the images under
`/img/` are served by one prefix location with a media type per extension. A `custom` or
`generated` file is served from `/var/www/getbible/<domain>/`, a `repository`
file from `/srv/getbible/<domain>/` through the version's current-release
symlink (with `open_file_cache off`, like the data). `/v2` without the slash
redirects to `/v2/`.

For a runtime endpoint the page location hands a request that carries a query
string or a body to the service, so `GET /v2/?q=...` and `POST /v2/` keep
working as they always did; a runtime domain whose endpoint sits at the root
does the same for `/`, through an internal-only prefix (`/.gb/`) that clients
cannot reach.

## versions.json

```json
{
  "domain": "api.getbible.net",
  "endpoints": [
    {"version": "v2", "url": "https://api.getbible.net/v2/", "openapi": "https://api.getbible.net/v2/openapi.json"}
  ]
}
```

Only enabled endpoints whose OpenAPI document is configured and present are
listed. The file exists (possibly with an empty list) for every domain,
including a single endpoint at its root. A root endpoint uses `/` and
`/openapi.json`; a runtime root entry names its implemented version (for example
`v2`). The singular `/version.json` address serves the same file.

The list comes from the current domain registry, with no advance inventory to
maintain. Adding/removing versions, applying settings, and successful syncs
refresh it automatically. Static specifications are trusted files from the
builder or operator; their absence never blocks data publication.
