"""Factory entry point: uvicorn getbible_mcp_api.asgi:create_app --factory."""

from .app import create_app

__all__ = ["create_app"]
