#!/usr/bin/env bash
# Detects whether Kyverno is already installed on the cluster so teardown
# knows whether it's safe to remove later. Sets KYVERNO_PREEXISTING and
# persists it to .demo-state/state.env.

check_kyverno() {
  local state_file
  state_file="$(repo_root)/.demo-state/state.env"
  mkdir -p "$(dirname "$state_file")"
  touch "$state_file"

  # Only ever record this once. setup.sh is idempotent and safe to re-run,
  # but by the second run Kyverno legitimately exists *because this repo
  # installed it* -- re-evaluating here would overwrite the true original
  # answer and make teardown wrongly think Kyverno pre-existed, silently
  # leaving it installed forever with no way to be offered removal again.
  if grep -q '^kyverno_preexisting=' "$state_file"; then
    KYVERNO_PREEXISTING="$(grep '^kyverno_preexisting=' "$state_file" | tail -1 | cut -d= -f2)"
    log_info "Kyverno pre-existing status already recorded from a previous run: ${KYVERNO_PREEXISTING}"
    export KYVERNO_PREEXISTING
    return 0
  fi

  if kubectl --context "$KUBE_CTX" get ns kyverno >/dev/null 2>&1; then
    KYVERNO_PREEXISTING="true"
    log_info "Kyverno namespace already exists -- treating Kyverno as pre-existing (teardown will not remove it)"
  else
    KYVERNO_PREEXISTING="false"
    log_info "no existing Kyverno install found"
  fi
  export KYVERNO_PREEXISTING
  echo "kyverno_preexisting=${KYVERNO_PREEXISTING}" >> "$state_file"
}
