#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

source scripts/lib/common.sh
source scripts/lib/check_prereqs.sh
source scripts/lib/kyverno_cli_bootstrap.sh
source scripts/lib/check_kyverno.sh
source scripts/lib/install_kyverno.sh
source scripts/lib/apply_namespaces.sh
source scripts/lib/apply_policy.sh
source scripts/lib/install_observability.sh
source scripts/lib/start_port_forward.sh
source scripts/lib/verify.sh

mkdir -p .demo-state

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  log_info "loaded .env"
else
  log_warn ".env not found -- copy .env.example to .env first (KUBE_CONTEXT/NAMESPACE_PREFIX matter for setup; LLM_MODEL/API keys are used when you run the demo)"
fi

# k3s's bundled `kubectl` ignores the usual ~/.kube/config default and
# looks at /etc/rancher/k3s/k3s.yaml (root-only) unless KUBECONFIG is set
# explicitly. Default it here rather than relying on kubectl's own fallback.
if [[ -z "${KUBECONFIG:-}" && -f "$HOME/.kube/config" ]]; then
  export KUBECONFIG="$HOME/.kube/config"
fi

: "${NAMESPACE_PREFIX:=pod-investigator}"
export NAMESPACE_PREFIX
export STAGING_NS="${NAMESPACE_PREFIX}-staging"
export PROD_NS="${NAMESPACE_PREFIX}-production"
export OBS_NS="${NAMESPACE_PREFIX}-observability"

log_step "1/9 Checking prerequisites"
check_prereqs

log_step "2/9 Bootstrapping kyverno CLI"
bootstrap_kyverno_cli

log_step "3/9 Checking for existing Kyverno install"
check_kyverno

log_step "4/9 Installing Kyverno (if needed)"
install_kyverno

log_step "5/9 Applying Kyverno golden-path policy"
apply_policy

log_step "6/9 Creating demo namespaces + dummy workloads"
apply_namespaces

log_step "7/9 Installing observability stack (OTel Collector + Jaeger + Grafana)"
install_observability

log_step "8/9 Setting up Python environment"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
if [[ -f requirements.txt ]]; then
  ./.venv/bin/pip install -q --upgrade pip
  ./.venv/bin/pip install -q -r requirements.txt
fi

log_step "9/9 Starting port-forwards"
start_port_forward

verify_setup

log_info "Setup complete."
log_info "Run demo/run_demo.sh to start the demo."
log_info "When finished: run scripts/teardown.sh to clean up."
