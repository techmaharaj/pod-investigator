#!/usr/bin/env bash
# Applies the golden-path ClusterPolicy live in-cluster. This is the same
# rendered YAML that mcp_server/policy_client.py later feeds to
# `kyverno apply` for the per-tool-call CLI check -- kept in one rendered
# location so both paths use an identical policy.

apply_policy() {
  local rendered_dir out
  rendered_dir="$(repo_root)/.demo-state/rendered"
  mkdir -p "$rendered_dir"
  render_template "$(repo_root)/k8s/kyverno-policy.yaml" "$rendered_dir/kyverno-policy.yaml"

  kubectl --context "$KUBE_CTX" apply -f "$rendered_dir/kyverno-policy.yaml"

  log_info "waiting for ClusterPolicy to become ready"
  out="$(kubectl --context "$KUBE_CTX" wait clusterpolicy/pod-investigator-agent-scope \
    --for=condition=Ready --timeout=60s 2>&1)" || {
      log_warn "policy did not report Ready within 60s (Kyverno may still be warming up): $out"
    }

  log_info "golden-path policy applied"
}
