"""Shared fixtures for the endpoint tests: the librarian fixture repository
and endpoint settings that point at it."""

from __future__ import annotations

import logging
import os
import tempfile
from pathlib import Path

FIXTURE_REPOSITORY = str(Path(__file__).parent / "fixtures" / "repository")


class EndpointCase:
    """Mixin: builds an app against the fixture repository in a temp cache."""

    prefix = "QUERY"

    def make_settings(self):  # pragma: no cover - overridden
        raise NotImplementedError

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.cache_dir = os.path.join(self.temporary.name, "cache")
        self.app_log = os.path.join(self.temporary.name, "app.log")
        self.app = self.make_app()
        self.app.testing = True
        self.client = self.app.test_client()

    def tearDown(self) -> None:
        self.app.extensions["getbible"].close()
        for name in ("getbible.query", "getbible.search"):
            logger = logging.getLogger(name)
            for handler in list(logger.handlers):
                handler.close()
            logger.handlers.clear()
        self.temporary.cleanup()

    def log_lines(self) -> list[str]:
        if not os.path.exists(self.app_log):
            return []
        with open(self.app_log, encoding="utf-8") as handle:
            return [line for line in handle.read().splitlines() if line]
