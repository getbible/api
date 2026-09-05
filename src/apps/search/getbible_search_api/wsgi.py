"""Gunicorn entry point."""

from .app import create_app

app = create_app()

__all__ = ["app"]
