#!/usr/bin/env bash
# Creates the 3 demo namespaces + the dummy crash-looping Deployment + the
# dummy Secret. Idempotent against our own previous runs (re-applying is
# safe), but refuses to touch a namespace that already exists and wasn't
# created by this repo -- that's someone else's namespace.

_assert_namespace_safe_to_use() {
  local ns="$1"
  if kubectl --context "$KUBE_CTX" get ns "$ns" >/dev/null 2>&1; then
    local owner
    owner="$(kubectl --context "$KUBE_CTX" get ns "$ns" -o jsonpath='{.metadata.labels.demo\.io/managed-by}' 2>/dev/null || true)"
    if [[ "$owner" != "pod-investigator" ]]; then
      log_error "namespace '$ns' already exists and was not created by this repo."
      log_error "set NAMESPACE_PREFIX in .env to something else and re-run."
      exit 1
    fi
    log_info "namespace '$ns' already exists (created by a previous run of this repo) -- reusing"
  fi
}

apply_namespaces() {
  _assert_namespace_safe_to_use "$STAGING_NS"
  _assert_namespace_safe_to_use "$PROD_NS"
  _assert_namespace_safe_to_use "$OBS_NS"

  local rendered_dir
  rendered_dir="$(repo_root)/.demo-state/rendered"
  mkdir -p "$rendered_dir"

  render_template "$(repo_root)/k8s/namespaces.yaml" "$rendered_dir/namespaces.yaml"
  kubectl --context "$KUBE_CTX" apply -f "$rendered_dir/namespaces.yaml"

  render_template "$(repo_root)/k8s/dummy-pod-checkout-service.yaml" "$rendered_dir/dummy-pod-checkout-service.yaml"
  kubectl --context "$KUBE_CTX" apply -f "$rendered_dir/dummy-pod-checkout-service.yaml"

  render_template "$(repo_root)/k8s/dummy-secret-db-credentials.yaml" "$rendered_dir/dummy-secret-db-credentials.yaml"
  kubectl --context "$KUBE_CTX" apply -f "$rendered_dir/dummy-secret-db-credentials.yaml"

  log_info "waiting for checkout-service pod to appear (it will crash-loop -- that's expected)"
  kubectl --context "$KUBE_CTX" -n "$STAGING_NS" wait --for=condition=PodScheduled \
    -l app=checkout-service --timeout=60s >/dev/null 2>&1 || true

  log_info "namespaces + dummy workloads applied"
}
