# Manual MCP client for local verification: spawns mcp_server/server.py
# over stdio and calls all 4 tools against the configured cluster. Not
# part of the demo itself -- a small harness to confirm the server is
# wired up correctly. Run from the repo root with the repo's venv active.
import asyncio
import json
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters, stdio_client

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
SERVER_PATH = REPO_ROOT / "mcp_server" / "server.py"


async def call(session: ClientSession, name: str, arguments: dict | None = None):
    print(f"\n=== {name}({arguments or {}}) ===")
    result = await session.call_tool(name, arguments or {})
    for block in result.content:
        if hasattr(block, "text"):
            print(block.text)
    return result


async def main():
    params = StdioServerParameters(
        command=sys.executable,
        args=[str(SERVER_PATH)],
        env=os.environ.copy(),
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()

            tools = await session.list_tools()
            print("registered tools:", [t.name for t in tools.tools])

            await call(session, "get_pod_status")
            await call(session, "get_pod_logs")
            await call(session, "restart_pod")
            await call(session, "get_secret")


if __name__ == "__main__":
    asyncio.run(main())
