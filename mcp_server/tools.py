# The 4 demo tools. Every call runs the Kyverno policy check first (see
# policy_client.py); only an allowed call ever touches k8s_client / kubectl.
# A denial never calls kubectl and returns a structured reason plus an
# escalation hint -- the golden path telling the agent what to do next.
import os
from typing import Any

import k8s_client
import policy_client
from identity import get_identity
from otel_setup import record_policy_decision, tool_span

NAMESPACE_PREFIX = os.environ.get("NAMESPACE_PREFIX", "pod-investigator")
STAGING_NS = f"{NAMESPACE_PREFIX}-staging"
PROD_NS = f"{NAMESPACE_PREFIX}-production"

ESCALATION_HINT = (
    "This action is outside your granted scope and was blocked before reaching "
    "the cluster. Do not retry -- open a human access request for this scope/tool."
)


def _denied_result(tool: str, reason: str) -> dict[str, Any]:
    return {
        "status": "denied",
        "tool": tool,
        "reason": reason,
        "next_step": ESCALATION_HINT,
    }


def get_pod_logs(
    pod_label_selector: str = "app=checkout-service",
    namespace: str = STAGING_NS,
    tail_lines: int = 100,
) -> dict[str, Any]:
    """Fetch recent logs for a pod matching a label selector."""
    identity = get_identity()
    with tool_span("get_pod_logs", identity.spiffe_id, namespace) as span:
        decision = policy_client.check_policy("get_pod_logs", namespace, identity)
        record_policy_decision(span, decision)
        if not decision.allowed:
            return _denied_result("get_pod_logs", decision.reason)

        logs = k8s_client.get_pod_logs(namespace, pod_label_selector, tail_lines)
        return {
            "status": "ok",
            "tool": "get_pod_logs",
            "logs": logs,
            "policy_enforced": decision.enforced,
        }


def get_pod_status(
    pod_label_selector: str = "app=checkout-service",
    namespace: str = STAGING_NS,
) -> dict[str, Any]:
    """Get status (phase, restart count, container states) for a pod matching a label selector."""
    identity = get_identity()
    with tool_span("get_pod_status", identity.spiffe_id, namespace) as span:
        decision = policy_client.check_policy("get_pod_status", namespace, identity)
        record_policy_decision(span, decision)
        if not decision.allowed:
            return _denied_result("get_pod_status", decision.reason)

        raw = k8s_client.get_pod_status(namespace, pod_label_selector)
        items = raw.get("items", [])
        summary = [
            {
                "name": item["metadata"]["name"],
                "phase": item.get("status", {}).get("phase"),
                "restart_count": (
                    item.get("status", {}).get("containerStatuses", [{}])[0].get("restartCount")
                ),
                "container_states": [
                    cs.get("state") for cs in item.get("status", {}).get("containerStatuses", [])
                ],
            }
            for item in items
        ]
        return {
            "status": "ok",
            "tool": "get_pod_status",
            "pods": summary,
            "policy_enforced": decision.enforced,
        }


def restart_pod(
    pod_label_selector: str = "app=checkout-service",
    namespace: str = STAGING_NS,
) -> dict[str, Any]:
    """Restart a pod (via delete, so its Deployment recreates it) matching a label selector."""
    identity = get_identity()
    with tool_span("restart_pod", identity.spiffe_id, namespace) as span:
        decision = policy_client.check_policy("restart_pod", namespace, identity)
        record_policy_decision(span, decision)
        if not decision.allowed:
            return _denied_result("restart_pod", decision.reason)

        output = k8s_client.delete_pod(namespace, pod_label_selector)
        return {
            "status": "ok",
            "tool": "restart_pod",
            "result": output.strip(),
            "policy_enforced": decision.enforced,
        }


def get_secret(
    secret_name: str = "db-credentials",
    namespace: str = PROD_NS,
) -> dict[str, Any]:
    """Read a Kubernetes Secret by name."""
    identity = get_identity()
    with tool_span("get_secret", identity.spiffe_id, namespace) as span:
        decision = policy_client.check_policy("get_secret", namespace, identity)
        record_policy_decision(span, decision)
        if not decision.allowed:
            return _denied_result("get_secret", decision.reason)

        raw = k8s_client.get_secret(namespace, secret_name)
        return {
            "status": "ok",
            "tool": "get_secret",
            "secret": raw,
            "policy_enforced": decision.enforced,
        }
