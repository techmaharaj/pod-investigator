#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

source scripts/lib/common.sh

KEEP_VENV=0
for arg in "$@"; do
  case "$arg" in
    --keep-venv) KEEP_VENV=1 ;;
  esac
done

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [[ -z "${KUBECONFIG:-}" && -f "$HOME/.kube/config" ]]; then
  export KUBECONFIG="$HOME/.kube/config"
fi

: "${NAMESPACE_PREFIX:=pod-investigator}"
STAGING_NS="${NAMESPACE_PREFIX}-staging"
PROD_NS="${NAMESPACE_PREFIX}-production"
OBS_NS="${NAMESPACE_PREFIX}-observability"

KUBE_CTX="${KUBE_CONTEXT:-}"
[[ -z "$KUBE_CTX" ]] && KUBE_CTX="$(kubectl config current-context)"

STATE_DIR=".demo-state"
STATE_FILE="$STATE_DIR/state.env"

log_step "1/6 Stopping port-forwards"
for name in grafana jaeger otel; do
  pid_file="$STATE_DIR/${name}.pid"
  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if kill "$pid" >/dev/null 2>&1; then
      log_info "stopped $name port-forward (pid $pid)"
    fi
    rm -f "$pid_file"
  fi
done

log_step "2/6 Removing observability stack"
if helm status jaeger -n "$OBS_NS" --kube-context "$KUBE_CTX" >/dev/null 2>&1; then
  helm uninstall jaeger -n "$OBS_NS" --kube-context "$KUBE_CTX" || true
fi
if helm status otel-collector -n "$OBS_NS" --kube-context "$KUBE_CTX" >/dev/null 2>&1; then
  helm uninstall otel-collector -n "$OBS_NS" --kube-context "$KUBE_CTX" || true
fi
if helm status grafana -n "$OBS_NS" --kube-context "$KUBE_CTX" >/dev/null 2>&1; then
  helm uninstall grafana -n "$OBS_NS" --kube-context "$KUBE_CTX" || true
fi
log_step "3/6 Removing demo namespaces"
_delete_if_managed_by_us() {
  local ns="$1"
  if ! kubectl --context "$KUBE_CTX" get ns "$ns" >/dev/null 2>&1; then
    return 0
  fi
  local owner
  owner="$(kubectl --context "$KUBE_CTX" get ns "$ns" -o jsonpath='{.metadata.labels.demo\.io/managed-by}' 2>/dev/null || true)"
  if [[ "$owner" == "pod-investigator" ]]; then
    kubectl --context "$KUBE_CTX" delete namespace "$ns"
  else
    log_warn "namespace '$ns' is not labeled demo.io/managed-by=pod-investigator -- skipping delete (not ours)"
  fi
}
_delete_if_managed_by_us "$STAGING_NS"
_delete_if_managed_by_us "$PROD_NS"
_delete_if_managed_by_us "$OBS_NS"

log_step "4/6 Removing golden-path policy"
kubectl --context "$KUBE_CTX" delete clusterpolicy pod-investigator-agent-scope --ignore-not-found

log_step "5/6 Kyverno cluster-wide install"
kyverno_preexisting="true"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi

if [[ "$kyverno_preexisting" == "false" ]]; then
  log_warn "This repo installed Kyverno cluster-wide during setup."
  if confirm "Uninstall Kyverno (removes the cluster-wide webhook, CRDs, and 'kyverno' namespace) now?"; then
    helm uninstall kyverno -n kyverno --kube-context "$KUBE_CTX" || true
    kubectl --context "$KUBE_CTX" delete namespace kyverno --ignore-not-found
    log_info "Kyverno removed"
  else
    log_warn "leaving Kyverno installed -- remove it manually later if you want a fully clean cluster"
  fi
else
  log_info "Kyverno was already present before this repo's setup ran -- leaving it untouched"
fi

log_step "6/6 Local cleanup"
rm -rf "$STATE_DIR"
if [[ "$KEEP_VENV" -eq 0 ]]; then
  rm -rf .venv
else
  log_info "keeping .venv (--keep-venv passed)"
fi

log_info "Teardown complete. Cluster should be back to its pre-demo state."
