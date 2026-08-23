#!/usr/bin/env bash
# Verifies local tooling + cluster reachability. Sets the global KUBE_CTX
# used by every other lib script.

check_prereqs() {
  local missing=0
  for cmd in kubectl helm python3 curl tar; do
    require_cmd "$cmd" || missing=1
  done
  if [[ "$missing" -eq 1 ]]; then
    log_error "install the missing command(s) above and re-run scripts/setup.sh"
    exit 1
  fi
  log_info "kubectl, helm, python3, curl, tar all present"

  KUBE_CTX="${KUBE_CONTEXT:-}"
  if [[ -z "$KUBE_CTX" ]]; then
    KUBE_CTX="$(kubectl config current-context)"
  fi
  export KUBE_CTX

  if ! kubectl --context "$KUBE_CTX" cluster-info >/dev/null 2>&1; then
    log_error "cannot reach the cluster for context '$KUBE_CTX'."
    log_error "check your kubeconfig / network (Tailscale, SSH tunnel, etc.) and try again."
    exit 1
  fi

  local server
  server="$(kubectl --context "$KUBE_CTX" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  log_info "target kube context : $KUBE_CTX"
  log_info "cluster API server  : $server"

  if ! confirm "About to create namespaces (${STAGING_NS}, ${PROD_NS}, ${OBS_NS}) and possibly install Kyverno cluster-wide on this cluster. Continue?"; then
    log_warn "aborted by user"
    exit 1
  fi
}
