#!/usr/bin/env bash
# Installs Kyverno cluster-wide via helm, sized down for a small homelab
# node. Only runs if check_kyverno.sh determined it isn't already present.
# This is the one genuinely cluster-wide (not namespace-scoped) action in
# setup.sh, so it gets its own explicit confirmation prompt.

install_kyverno() {
  if [[ "$KYVERNO_PREEXISTING" == "true" ]]; then
    log_info "skipping Kyverno install (already present)"
    return 0
  fi

  log_warn "Kyverno is not installed. Installing it adds a cluster-wide"
  log_warn "ValidatingAdmissionWebhook, CRDs, and a 'kyverno' namespace --"
  log_warn "this affects the whole cluster's admission control, not just"
  log_warn "the demo namespaces."
  if ! confirm "Install Kyverno cluster-wide now?"; then
    log_error "Kyverno is required for this demo. Aborting."
    exit 1
  fi

  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
  helm repo update kyverno >/dev/null

  helm install kyverno kyverno/kyverno \
    --kube-context "$KUBE_CTX" \
    --namespace kyverno \
    --create-namespace \
    --values "$(repo_root)/k8s/kyverno-values.yaml" \
    --wait --timeout 3m

  log_info "waiting for Kyverno admission-controller to be ready"
  kubectl --context "$KUBE_CTX" -n kyverno rollout status deployment \
    -l app.kubernetes.io/component=admission-controller --timeout=120s

  log_info "Kyverno installed"
}
