"""Validate the installed MCP package and lifespan without contacting any upstream."""

from __future__ import annotations

import asyncio
import json

import httpx
from getbible_mcp import __version__

from .app import create_app


async def check() -> dict[str, str]:
    app = create_app()
    async with (
        app.router.lifespan_context(app),
        httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://127.0.0.1",
        ) as client,
    ):
        response = await client.get("/readyz")
        response.raise_for_status()
    return {"status": "ok", "mcp_endpoint": "/mcp", "library_version": __version__}


def main() -> None:
    print(json.dumps(asyncio.run(check())))


if __name__ == "__main__":
    main()
