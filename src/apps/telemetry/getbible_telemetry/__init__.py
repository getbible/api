"""Local, dependency-free getBible traffic history.

Writers belong to the collector. Dashboard and CLI consumers open read-only
connections; expensive reporting is never performed by request handlers.
"""

from .store import TelemetryStore

__all__ = ["TelemetryStore"]
