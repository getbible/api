"""Cached local endpoint configuration and translation book names for ingestion.

Only small registry files and books.json are read. The collector never loads a
Bible corpus, validates repository contents, or contacts a public API.
"""

from __future__ import annotations

import json
import re
import time
from pathlib import Path


def _settings(path: Path) -> dict[str, str]:
    result = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            key, separator, value = line.partition("=")
            if separator and re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
                # cfg_set stores raw one-line values, not shell syntax.
                result[key] = value
    except OSError:
        pass
    return result


class LocalCatalog:
    def __init__(self, registry="/etc/getbible/endpoints", data_root="/srv/getbible"):
        self.registry, self.data_root = Path(registry), Path(data_root)
        self._domains = {}
        self._books = {}
        self._next_refresh = 0.0

    def _refresh(self):
        if time.monotonic() < self._next_refresh:
            return
        self._next_refresh = time.monotonic() + 30
        domains = {}
        for path in self.registry.glob("*/endpoint.conf"):
            config = _settings(path)
            versions = {file.stem: _settings(file) for file in (path.parent / "versions").glob("*.conf")}
            domains[path.parent.name] = (config, versions)
        self._domains = domains

    def endpoint(self, domain, version):
        self._refresh()
        config, versions = self._domains.get(domain, ({}, {}))
        if config.get("TYPE") == "mcp" or config.get("KIND") == "mcp":
            return {"kind": "mcp", "version": "", "label": "", "repository": "",
                    "default_translation": ""}
        label = version if version in versions else "root" if "root" in versions else config.get("DEFAULT_ENDPOINT", "")
        selected = versions.get(label, {})
        return {"kind": config.get("KIND", config.get("TYPE", "")),
                "version": selected.get("APP_VERSION") or (label if label != "root" else ""),
                "label": label, "repository": selected.get("REPOSITORY", ""),
                "default_translation": selected.get("DEFAULT_TRANSLATION") or "kjv"}

    def books(self, domain, version, translation):
        # A translation can originate in a request path; never let it escape
        # the manager's known local repository paths.
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", translation):
            return {}
        endpoint = self.endpoint(domain, version)
        key = (domain, version, translation, endpoint["repository"])
        cached = self._books.get(key)
        if cached and time.monotonic() < cached[0]:
            return cached[1]
        roots = []
        if endpoint["repository"].startswith("/"):
            repository = Path(endpoint["repository"])
            roots += [repository / "v2", repository / version, repository]
        # Translation metadata is published in v2 even when another version
        # is being served. Root endpoints expose that same tree at /.
        roots += [self.data_root / domain / "v2"]
        if endpoint["label"]:
            roots += [self.data_root / domain / endpoint["label"]]
        names = {}
        for root in dict.fromkeys(roots):
            try:
                data = json.loads((root / translation / "books.json").read_text(encoding="utf-8"))
                entries = data.items() if isinstance(data, dict) else enumerate(data) if isinstance(data, list) else ()
                for identity, book in entries:
                    if isinstance(book, dict) and book.get("name"):
                        number = str(book.get("nr", book.get("book_nr", identity)))
                        if number.isdigit():
                            names[number] = str(book["name"])
                if names:
                    break
            except (OSError, ValueError, TypeError):
                continue
        # Bound memory even when unknown translation names are probed.
        if len(self._books) >= 1024:
            self._books.pop(next(iter(self._books)))
        self._books[key] = (time.monotonic() + 30, names)
        return names
