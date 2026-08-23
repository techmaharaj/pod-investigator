#!/usr/bin/env python3
# CLI entrypoint: `python trigger.py "<task text>"`. Prints the identity
# banner, spawns mcp_server/server.py over stdio (via llm_agent.run_agent),
# and prints a banner for every tool call/result plus the final incident
# summary. Generates one trace ID per invocation (AGENT_TRACE_ID) so the
# printed banner and the Jaeger trace for this run are the same ID -- see
# mcp_server/otel_setup.py for how the server subprocess picks it up.
import asyncio
import json
import os
import sys
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from llm_agent import run_agent  # noqa: E402

COLOR_RESET = "\033[0m"
COLOR_BLUE = "\033[34m"
COLOR_GREEN = "\033[32m"
COLOR_YELLOW = "\033[33m"
COLOR_RED = "\033[31m"
COLOR_BOLD = "\033[1m"


def _load_dotenv() -> None:
    env_path = REPO_ROOT / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key and key not in os.environ:
            os.environ[key] = value.strip()


def _print_identity_banner(trace_id: str) -> None:
    # SPIFFE_ID present (any value) means a claim was made -- whether that
    # claim is actually trusted is the policy's call, not something this
    # banner can know in advance, so it isn't color-coded either way.
    # Missing entirely (pass 1: no identity issuance) is the one case this
    # banner itself can honestly flag red.
    raw_spiffe_id = os.environ.get("SPIFFE_ID", "spiffe://homelab/deploy-bot")
    has_identity = bool(raw_spiffe_id)
    spiffe_id = raw_spiffe_id or "(none -- no identity issued)"
    scope = os.environ.get("SPIFFE_SCOPE", "staging") or "(none)"
    model = os.environ.get("LLM_MODEL", "anthropic/claude-haiku-4-5-20251001")
    policy_enforced = os.environ.get("POLICY_ENFORCEMENT", "on").lower() != "off"
    id_color = "" if has_identity else COLOR_RED
    print(f"{COLOR_BOLD}{COLOR_BLUE}=== Deploy-Bot identity ==={COLOR_RESET}")
    print(f"  spiffe.id:    {id_color}{spiffe_id}{COLOR_RESET}")
    print(f"  spiffe.scope: {scope}")
    print(f"  model:        {model}")
    print(f"  policy:       {COLOR_GREEN + 'enforced' if policy_enforced else COLOR_RED + 'NOT enforced'}{COLOR_RESET}")
    print(f"  trace.id:     {trace_id}")
    print()


def _on_event(event: str, **kwargs) -> None:
    if event == "model_used":
        print(f"{COLOR_BOLD}[model: {kwargs['model']}]{COLOR_RESET}")
        return

    if event == "tool_call":
        name = kwargs["name"]
        arguments = kwargs["arguments"]
        print(f"{COLOR_BOLD}{COLOR_BLUE}--> calling tool:{COLOR_RESET} {name}({json.dumps(arguments)})")
        return

    if event == "tool_result":
        name = kwargs["name"]
        result = kwargs["result"]
        parsed = None
        try:
            parsed = json.loads(result)
        except json.JSONDecodeError:
            pass

        status = parsed.get("status") if isinstance(parsed, dict) else None
        if status == "denied":
            reason = parsed.get("reason", "")
            print(f"{COLOR_RED}<-- DENIED:{COLOR_RESET} {name}: {reason}")
        elif status == "ok":
            if isinstance(parsed, dict) and parsed.get("policy_enforced") is False:
                print(f"{COLOR_RED}<-- UNCHECKED (no policy enforcement):{COLOR_RESET} {name}")
            else:
                print(f"{COLOR_GREEN}<-- ok:{COLOR_RESET} {name}")
        else:
            print(f"{COLOR_YELLOW}<-- {name} returned:{COLOR_RESET} {result[:200]}")
        return

    if event == "final":
        print()
        print(f"{COLOR_BOLD}{COLOR_GREEN}=== Incident summary ==={COLOR_RESET}")
        print(kwargs["text"])


def main() -> None:
    if len(sys.argv) < 2:
        print('usage: python trigger.py "<task text>"', file=sys.stderr)
        sys.exit(1)

    task = sys.argv[1]
    _load_dotenv()

    # k3s's bundled kubectl (invoked by mcp_server/k8s_client.py) ignores
    # ~/.kube/config unless KUBECONFIG is set explicitly -- same fix as
    # scripts/setup.sh, needed here too since trigger.py can be run directly.
    if "KUBECONFIG" not in os.environ:
        default_kubeconfig = Path.home() / ".kube" / "config"
        if default_kubeconfig.exists():
            os.environ["KUBECONFIG"] = str(default_kubeconfig)

    # scripts/lib/kyverno_cli_bootstrap.sh downloads the kyverno CLI (used by
    # mcp_server/policy_client.py for the per-call check) into .demo-state/bin
    # rather than the system PATH -- add it here too for a standalone run.
    demo_state_bin = REPO_ROOT / ".demo-state" / "bin"
    if demo_state_bin.is_dir():
        os.environ["PATH"] = f"{demo_state_bin}{os.pathsep}{os.environ.get('PATH', '')}"

    trace_id = uuid.uuid4().hex
    os.environ["AGENT_TRACE_ID"] = trace_id

    _print_identity_banner(trace_id)
    print(f"{COLOR_BOLD}task:{COLOR_RESET} {task}\n")

    asyncio.run(run_agent(task, on_event=_on_event))


if __name__ == "__main__":
    main()
