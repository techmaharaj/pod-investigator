# MCP server over stdio, registering the 4 demo tools. Run directly
# (`python mcp_server/server.py`) or spawned by agent/trigger.py.
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from mcp.server.mcpserver import MCPServer

import tools
from otel_setup import init_tracing, shutdown_tracing

mcp = MCPServer("pod-investigator")

mcp.tool()(tools.get_pod_logs)
mcp.tool()(tools.get_pod_status)
mcp.tool()(tools.restart_pod)
mcp.tool()(tools.get_secret)


def main() -> None:
    init_tracing()
    try:
        mcp.run(transport="stdio")
    finally:
        shutdown_tracing()


if __name__ == "__main__":
    main()
