# Provider-agnostic tool-use loop. Uses litellm so swapping providers is a
# one-line change to LLM_MODEL in .env -- no code here is Anthropic- or
# OpenAI-specific. Lists tools from mcp_server/server.py over stdio, converts
# them to the OpenAI-style tool schema litellm expects for every provider,
# and runs the standard loop: send messages -> model emits tool_calls -> call
# the MCP tool -> feed the result back as a tool message -> repeat until the
# model responds with no more tool calls.
import json
import os
import sys
from pathlib import Path
from typing import Any, Awaitable, Callable

import litellm
from mcp import ClientSession, StdioServerParameters, stdio_client

from prompts import SYSTEM_PROMPT

# litellm prints a "Provider List" hint to stderr whenever its first attempt
# at resolving a model string's provider fails internally before a fallback
# path succeeds -- harmless (the call still completes correctly) but noisy
# on a live-demo terminal, and specifically fires for double-prefixed model
# strings like openrouter/openrouter/free.
litellm.suppress_debug_info = True

REPO_ROOT = Path(__file__).resolve().parent.parent
SERVER_PATH = REPO_ROOT / "mcp_server" / "server.py"

MAX_TURNS = 10

EventHandler = Callable[..., None]


async def _list_tool_schemas(session: ClientSession) -> list[dict]:
    listed = await session.list_tools()
    return [
        {
            "type": "function",
            "function": {
                "name": t.name,
                "description": t.description or "",
                "parameters": t.input_schema or {"type": "object", "properties": {}},
            },
        }
        for t in listed.tools
    ]


async def _call_mcp_tool(session: ClientSession, name: str, arguments: dict) -> str:
    result = await session.call_tool(name, arguments)
    parts = [block.text for block in result.content if hasattr(block, "text")]
    if parts:
        return "\n".join(parts)
    return json.dumps({"status": "error", "message": f"{name} returned no content"})


async def run_agent(task: str, on_event: EventHandler | None = None) -> str:
    def emit(event: str, **kwargs: Any) -> None:
        if on_event is not None:
            on_event(event, **kwargs)

    model = os.environ.get("LLM_MODEL", "anthropic/claude-haiku-4-5-20251001")
    params = StdioServerParameters(
        command=sys.executable,
        args=[str(SERVER_PATH)],
        env=os.environ.copy(),
    )

    try:
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await _list_tool_schemas(session)

                messages: list[dict] = [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": task},
                ]

                for _ in range(MAX_TURNS):
                    response = await litellm.acompletion(
                        model=model,
                        messages=messages,
                        tools=tools,
                    )
                    # response.model is the actual resolved model for this
                    # call -- with a router alias like openrouter/free, that
                    # can differ from `model` (the alias) on every single
                    # turn, so this is emitted per-turn, not just once.
                    emit("model_used", model=response.model)
                    message = response.choices[0].message
                    messages.append(message.model_dump(exclude_none=True))

                    tool_calls = message.tool_calls or []
                    if not tool_calls:
                        final_text = message.content or ""
                        emit("final", text=final_text)
                        return final_text

                    for tool_call in tool_calls:
                        name = tool_call.function.name
                        try:
                            arguments = json.loads(tool_call.function.arguments or "{}")
                        except json.JSONDecodeError:
                            arguments = {}

                        emit("tool_call", name=name, arguments=arguments)
                        result_text = await _call_mcp_tool(session, name, arguments)
                        emit("tool_result", name=name, result=result_text)

                        messages.append(
                            {
                                "role": "tool",
                                "tool_call_id": tool_call.id,
                                "content": result_text,
                            }
                        )

                final_text = "(stopped: reached max turns without a final answer)"
                emit("final", text=final_text)
                return final_text
    finally:
        # Without this, litellm's cached async httpx clients get torn down
        # by the asyncio.run() event-loop shutdown instead of closed
        # cleanly, spamming "Event loop is closed" tracebacks on exit.
        await litellm.close_litellm_async_clients()
