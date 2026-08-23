# Thin subprocess wrapper around kubectl -- the only place tools.py actually
# touches the cluster once a call has cleared the policy check.
import json
import os
import subprocess

KUBE_CONTEXT = os.environ.get("KUBE_CONTEXT") or None


class KubectlError(RuntimeError):
    pass


def _run(*args: str) -> str:
    cmd = ["kubectl"]
    if KUBE_CONTEXT:
        cmd += ["--context", KUBE_CONTEXT]
    cmd += list(args)

    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise KubectlError(result.stderr.strip() or f"kubectl {' '.join(args)} failed")
    return result.stdout


def get_pod_logs(namespace: str, pod_label_selector: str, tail_lines: int = 100) -> str:
    return _run(
        "-n", namespace, "logs",
        "-l", pod_label_selector,
        "--tail", str(tail_lines),
        "--all-containers",
    )


def get_pod_status(namespace: str, pod_label_selector: str) -> dict:
    raw = _run("-n", namespace, "get", "pods", "-l", pod_label_selector, "-o", "json")
    return json.loads(raw)


def delete_pod(namespace: str, pod_label_selector: str) -> str:
    return _run("-n", namespace, "delete", "pod", "-l", pod_label_selector)


def get_secret(namespace: str, secret_name: str) -> dict:
    raw = _run("-n", namespace, "get", "secret", secret_name, "-o", "json")
    return json.loads(raw)
