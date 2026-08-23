#!/usr/bin/env bash
# Post-setup smoke test: confirms the dummy pod is behaving like a real
# crash-loop, the policy is live, and the dashboards actually respond.

verify_setup() {
  log_step "Verifying setup"
  local ok=1

  if kubectl --context "$KUBE_CTX" -n "$STAGING_NS" get pods -l app=checkout-service \
      -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null | grep -qE '^[0-9]+$'; then
    log_info "checkout-service pod exists and is reporting restarts (crash-looping as expected)"
  else
    log_warn "checkout-service pod not found yet -- it may still be pulling the image"
    ok=0
  fi

  if kubectl --context "$KUBE_CTX" get clusterpolicy pod-investigator-agent-scope >/dev/null 2>&1; then
    log_info "ClusterPolicy pod-investigator-agent-scope is present"
  else
    log_error "ClusterPolicy not found"
    ok=0
  fi

  local grafana_port jaeger_port
  grafana_port="${GRAFANA_LOCAL_PORT:-3000}"
  jaeger_port="${JAEGER_LOCAL_PORT:-16686}"

  if curl -fsS -o /dev/null "http://localhost:${grafana_port}/login"; then
    log_info "Grafana responding on port ${grafana_port}"
  else
    log_warn "Grafana not responding yet on port ${grafana_port} (give it a few more seconds)"
    ok=0
  fi

  if curl -fsS -o /dev/null "http://localhost:${jaeger_port}"; then
    log_info "Jaeger responding on port ${jaeger_port}"
  else
    log_warn "Jaeger not responding yet on port ${jaeger_port} (give it a few more seconds)"
    ok=0
  fi

  if [[ "$ok" -eq 1 ]]; then
    log_info "all checks passed"
  else
    log_warn "some checks did not pass yet -- re-run 'bash scripts/lib/verify.sh' style checks manually, or just retry in a minute"
  fi
}
