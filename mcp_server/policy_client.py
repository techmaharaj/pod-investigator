# Evaluates every tool call -- read or write -- against the real Kyverno
# policy engine via the `kyverno apply` CLI, using a synthetic Pod/Secret
# manifest that stands in for the call. Real K8s admission control only
# intercepts writes, so this CLI dry-run against the exact same ClusterPolicy
# YAML is the honest way to enforce the golden path on reads too, without
# hand-waving "real Kyverno" into a mock. See the README ("Architecture").
import json
import os
import re
import subprocess
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path

from identity import Identity

REPO_ROOT = Path(__file__).resolve().parent.parent
RENDERED_POLICY_PATH = REPO_ROOT / ".demo-state" / "rendered" / "kyverno-policy.yaml"
RAW_POLICY_PATH = REPO_ROOT / "k8s" / "kyverno-policy.yaml"

NAMESPACE_PREFIX = os.environ.get("NAMESPACE_PREFIX", "pod-investigator")
STAGING_NS = f"{NAMESPACE_PREFIX}-staging"
PROD_NS = f"{NAMESPACE_PREFIX}-production"

# Demo-only escape hatch: POLICY_ENFORCEMENT=off simulates the pre-golden-path
# state (no Kyverno policy checking anything) for demo/run_demo.sh's contrast
# pass. Every real check still goes through the CLI below; this is a
# deliberate, narrated bypass, not a code path that's ever silent about it --
# see the "enforced" field on PolicyDecision and how it's surfaced.
POLICY_ENFORCEMENT = os.environ.get("POLICY_ENFORCEMENT", "on").lower() != "off"

# Which synthetic resource kind each tool's call is represented as -- mirrors
# the real dummy objects the tool would actually touch (Pod actions vs. the
# Secret read).
TOOL_KIND = {
    "get_pod_logs": "Pod",
    "get_pod_status": "Pod",
    "restart_pod": "Pod",
    "get_secret": "Secret",
}


@dataclass(frozen=True)
class PolicyDecision:
    allowed: bool
    reason: str
    enforced: bool = True


def _resolve_policy_path() -> Path:
    # Prefer the namespace-rendered policy written by scripts/lib/apply_policy.sh
    # (same file the live in-cluster ClusterPolicy was applied from). Fall back
    # to rendering it ourselves so the server also works standalone.
    if RENDERED_POLICY_PATH.exists():
        return RENDERED_POLICY_PATH

    text = RAW_POLICY_PATH.read_text()
    text = text.replace("${NAMESPACE_PREFIX}", NAMESPACE_PREFIX)
    text = text.replace("${STAGING_NS}", STAGING_NS)
    text = text.replace("${PROD_NS}", PROD_NS)
    RENDERED_POLICY_PATH.parent.mkdir(parents=True, exist_ok=True)
    RENDERED_POLICY_PATH.write_text(text)
    return RENDERED_POLICY_PATH


def _build_synthetic_manifest(tool: str, namespace: str, identity: Identity) -> dict:
    kind = TOOL_KIND[tool]
    name = f"synthetic-{tool}-{uuid.uuid4().hex[:8]}"
    metadata = {
        "name": name,
        "namespace": namespace,
        "labels": {"demo.io/synthetic-check": "true"},
        "annotations": {
            "demo.io/identity": identity.spiffe_id,
            "demo.io/scope": identity.scope,
            "demo.io/tool": tool,
        },
    }

    if kind == "Pod":
        return {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": metadata,
            "spec": {
                "containers": [{"name": "synthetic-check", "image": "busybox:1.36"}],
            },
        }

    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": metadata,
        "type": "Opaque",
        "stringData": {"placeholder": "synthetic-check"},
    }


_FAILED_RULE_RE = re.compile(r"^\d+\s*-\s*\S+\s+(.*)$")


def _parse_kyverno_output(returncode: int, stdout: str, stderr: str) -> PolicyDecision:
    output = stdout + stderr

    # `kyverno apply` prints one line per failed rule as:
    #   1 - <rule-name> <message>
    # (message is the policy's own `validate.message`, which already starts
    # with "denied: ...") and exits non-zero when any rule failed.
    for line in output.splitlines():
        match = _FAILED_RULE_RE.match(line.strip())
        if match:
            return PolicyDecision(allowed=False, reason=match.group(1).strip())

    if returncode == 0:
        return PolicyDecision(allowed=True, reason="allowed: no policy rule denied this action")

    return PolicyDecision(
        allowed=False,
        reason=f"denied: kyverno apply failed without a parseable validation message: {output.strip()}",
    )


def check_policy(tool: str, namespace: str, identity: Identity) -> PolicyDecision:
    if not POLICY_ENFORCEMENT:
        return PolicyDecision(
            allowed=True,
            reason=(
                "no policy enforcement configured -- this call was never checked "
                "(POLICY_ENFORCEMENT=off: simulating the pre-golden-path state)"
            ),
            enforced=False,
        )

    policy_path = _resolve_policy_path()
    manifest = _build_synthetic_manifest(tool, namespace, identity)

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", prefix="synthetic-check-", delete=False
    ) as f:
        json.dump(manifest, f)
        manifest_path = f.name

    try:
        result = subprocess.run(
            ["kyverno", "apply", str(policy_path), "--resource", manifest_path],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return _parse_kyverno_output(result.returncode, result.stdout, result.stderr)
    finally:
        os.unlink(manifest_path)
