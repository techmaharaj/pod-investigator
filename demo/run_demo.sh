#!/usr/bin/env bash
# Interactive, narrated demo runner. Wraps agent/trigger.py, pausing for
# [Enter] after each stage so a presenter can talk over it. Pass --no-pause
# for an unattended run with no pauses (also useful as a timing check).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

source scripts/lib/common.sh
source scripts/lib/kyverno_cli_bootstrap.sh

PAUSE=true
TASK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pause) PAUSE=false ;;
    *) TASK="$1" ;;
  esac
  shift
done
: "${TASK:=Investigate why the checkout-service pod in staging is crash-looping and find the root cause.}"

if [[ ! -f .env ]]; then
  cp .env.example .env
  log_warn "no .env found -- created one from .env.example. Fill in ANTHROPIC_API_KEY (or the key matching LLM_MODEL) if this preflight doesn't catch it."
fi
set -a
# shellcheck disable=SC1091
source .env
set +a

# Sets/updates KEY=VALUE in .env in place (adds the line if it's not there
# yet). Used below so a context or API key entered interactively persists
# for next time instead of being re-asked every run.
_set_env_var() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" -F= 'BEGIN{OFS="="} $1==k{$0=k"="v; found=1} {print} END{if(!found) print k"="v}' .env > "$tmp"
  mv "$tmp" .env
}

# Same k3s kubectl/KUBECONFIG fix as scripts/setup.sh and agent/trigger.py.
if [[ -z "${KUBECONFIG:-}" && -f "$HOME/.kube/config" ]]; then
  export KUBECONFIG="$HOME/.kube/config"
fi

: "${NAMESPACE_PREFIX:=pod-investigator}"
: "${GRAFANA_LOCAL_PORT:=3000}"
: "${JAEGER_LOCAL_PORT:=16686}"
: "${OTEL_LOCAL_PORT:=4317}"
: "${STAGING_NS:=${NAMESPACE_PREFIX}-staging}"
: "${PROD_NS:=${NAMESPACE_PREFIX}-production}"
: "${OBS_NS:=${NAMESPACE_PREFIX}-observability}"

TOTAL_STAGES=7
STAGE_NUM=0
DEMO_START=$(date +%s)
TMP_LOGS=()
trap 'rm -f "${TMP_LOGS[@]}"' EXIT

# ── Stage 0: preflight -- get this runnable with nothing but a Tailscale
#    connection and an API key, prompting for anything missing instead of
#    just failing partway through the narrated demo. ──────────────────────
log_step "Preflight"

# 1. kube context: reuse it if already set and reachable, otherwise list
#    what's available and ask.
KUBE_CTX="${KUBE_CONTEXT:-}"
if [[ -z "$KUBE_CTX" ]]; then
  KUBE_CTX="$(kubectl config current-context 2>/dev/null || true)"
fi
if [[ -z "$KUBE_CTX" ]] || ! kubectl --context "$KUBE_CTX" cluster-info >/dev/null 2>&1; then
  log_warn "kube context '${KUBE_CTX:-<none>}' isn't set or isn't reachable (check Tailscale)."
  echo "Available contexts:"
  kubectl config get-contexts -o name | sed 's/^/  - /'
  read -r -p "Enter the kube context to use: " KUBE_CTX
  if ! kubectl --context "$KUBE_CTX" cluster-info >/dev/null 2>&1; then
    log_error "still can't reach the cluster via context '$KUBE_CTX'. Check Tailscale/kubeconfig and re-run."
    exit 1
  fi
  _set_env_var KUBE_CONTEXT "$KUBE_CTX"
  log_info "saved KUBE_CONTEXT=$KUBE_CTX to .env"
fi
export KUBE_CONTEXT="$KUBE_CTX"
log_info "kube context: $KUBE_CTX (reachable)"

# 1b. Observability host: the machine running this script and the machine
#     hosting the Grafana/Jaeger/OTel port-forwards (started by setup.sh)
#     are not necessarily the same box -- e.g. presenting from a laptop
#     against a homelab cluster host over Tailscale. Guessing this
#     machine's own network identity (its Tailscale IP, its hostname) is
#     wrong in that case; the kube API server's address in this context is
#     always right, since that's the same host setup.sh ran on.
CLUSTER_SERVER="$(kubectl --context "$KUBE_CTX" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
OBS_HOST="$(echo "$CLUSTER_SERVER" | sed -E 's#^https?://##; s#:[0-9]+$##')"
[[ -z "$OBS_HOST" ]] && OBS_HOST="localhost"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://${OBS_HOST}:${OTEL_LOCAL_PORT}"
log_info "observability host: $OBS_HOST (from the kube API server address; overrides OTEL_EXPORTER_OTLP_ENDPOINT in .env)"

# 2. python venv: create + install deps if this is a fresh checkout.
if [[ ! -d .venv ]]; then
  log_info "no .venv found -- creating one and installing requirements.txt"
  python3 -m venv .venv
  ./.venv/bin/pip install -q --upgrade pip
  ./.venv/bin/pip install -q -r requirements.txt
fi
PYTHON_BIN="$ROOT_DIR/.venv/bin/python3"

# 3. LLM API key: figure out which env var LLM_MODEL's provider needs
#    (litellm convention: <PROVIDER>_API_KEY) and ask for it if unset.
: "${LLM_MODEL:=anthropic/claude-haiku-4-5-20251001}"
PROVIDER="${LLM_MODEL%%/*}"
KEY_VAR="$(echo "$PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY"
if [[ -z "${!KEY_VAR:-}" ]]; then
  log_warn "$KEY_VAR is not set (needed for LLM_MODEL=$LLM_MODEL)."
  read -r -s -p "Paste $KEY_VAR now (or press Enter to skip and fail later): " KEY_INPUT
  echo
  if [[ -n "$KEY_INPUT" ]]; then
    _set_env_var "$KEY_VAR" "$KEY_INPUT"
    export "$KEY_VAR=$KEY_INPUT"
    log_info "saved $KEY_VAR to .env"
  else
    log_warn "continuing without $KEY_VAR -- the agent's first LLM call will fail"
  fi
else
  log_info "$KEY_VAR is set"
fi

# 4. kyverno CLI: mcp_server/policy_client.py shells out to it for every
#    policy check. scripts/setup.sh downloads it into .demo-state/bin when
#    run on the cluster host -- do the same here if it's missing locally.
bootstrap_kyverno_cli

pause_stage() {
  STAGE_NUM=$((STAGE_NUM + 1))
  echo
  log_step "Stage ${STAGE_NUM}/${TOTAL_STAGES}: $1"
  if [[ "$PAUSE" == true ]]; then
    read -r -p "$(printf "${COLOR_YELLOW}[Enter to continue]${COLOR_RESET}")" _
  fi
}

# Echoes a command as text, then actually runs it -- so what's on screen is
# never narration standing in for a real command, it's the real command.
show_and_run() {
  printf "${COLOR_BOLD}\$ %s${COLOR_RESET}\n" "$*"
  "$@"
}

# Runs agent/trigger.py with the given identity/scope/policy env overrides,
# streaming its output live -- the identity banner and policy line it
# prints are the on-screen receipt for what this pass's config actually
# was. Sets TRACE_ID and PASS_SUMMARY (one "tool: verdict" line per tool
# call this pass actually made -- used for stage 7's recap table, built
# from what really happened, not from assumptions about which tools each
# pass would reach).
run_pass() {
  local spiffe_id="$1" spiffe_scope="$2" policy_enforcement="$3"
  local log_file
  log_file="$(mktemp)"
  TMP_LOGS+=("$log_file")

  if [[ "$PAUSE" == true ]]; then
    read -r -p "$(printf "${COLOR_YELLOW}[Enter to run]${COLOR_RESET}")" _
  fi

  SPIFFE_ID="$spiffe_id" SPIFFE_SCOPE="$spiffe_scope" POLICY_ENFORCEMENT="$policy_enforcement" \
    "$PYTHON_BIN" -u agent/trigger.py "$TASK" 2>&1 | tee "$log_file"

  TRACE_ID="$(grep -oE 'trace\.id:[[:space:]]*[0-9a-f]{32}' "$log_file" | awk '{print $2}' | head -1)"

  PASS_SUMMARY="$(
    sed -E 's/\x1b\[[0-9;]*m//g' "$log_file" \
      | grep -E '^<-- ' \
      | sed -E \
          -e 's/^<-- DENIED: ([a-zA-Z_]+):.*/\1: denied/' \
          -e 's/^<-- UNCHECKED \(no policy enforcement\): ([a-zA-Z_]+)/\1: unchecked/' \
          -e 's/^<-- ok: ([a-zA-Z_]+)/\1: ok/' \
      || true
  )"
}

# Colors the "tool: verdict" lines PASS_SUMMARY produces for the stage 7
# recap table -- same red/green convention as the live run itself. Uses
# printf (not sed) for the substitution: COLOR_RED/COLOR_GREEN are literal
# \033[...] text that only printf's format-string parser turns into a real
# escape sequence -- sed would print it as literal backslash-zero-three-three.
colorize_verdicts() {
  local line
  while IFS= read -r line; do
    case "$line" in
      *": denied") printf "${COLOR_BOLD}%s${COLOR_RESET}: ${COLOR_RED}denied${COLOR_RESET}\n" "${line%: denied}" ;;
      *": unchecked") printf "${COLOR_BOLD}%s${COLOR_RESET}: ${COLOR_RED}unchecked${COLOR_RESET}\n" "${line%: unchecked}" ;;
      *": ok") printf "${COLOR_BOLD}%s${COLOR_RESET}: ${COLOR_GREEN}ok${COLOR_RESET}\n" "${line%: ok}" ;;
      *) printf "%s\n" "$line" ;;
    esac
  done
}

# ── Stage 1: the plan ────────────────────────────────────────────────────
pause_stage "The plan"
cat <<EOF
Task, unchanged across all three passes:
  "${TASK}"

  Pass 1: no golden path.       No identity issuance, no policy enforcement.
  Pass 2: identity, no grant.   A real policy is enforced, but nobody
                                 registered this agent's identity.
  Pass 3: the golden path.      A real, scoped identity -- and the same
                                 policy enforced against it.
EOF

# ── Stage 2: prove it, with plain kubectl -- no agent, no LLM ──────────
pause_stage "Proof: is it actually broken?"
show_and_run kubectl --context "$KUBE_CTX" -n "$STAGING_NS" get pods
echo
show_and_run kubectl --context "$KUBE_CTX" -n "$STAGING_NS" logs -l app=checkout-service --tail=15

# ── Stage 3: Pass 1 -- no golden path ───────────────────────────────────
pause_stage "Pass 1 -- no golden path (ungoverned)"
run_pass "" "" "off"
PASS1_SUMMARY="$PASS_SUMMARY"

# ── Stage 4: Pass 2 -- identity without a grant ─────────────────────────
pause_stage "Pass 2 -- identity without a grant"
show_and_run grep -n 'spiffe://homelab/deploy-bot' k8s/kyverno-policy.yaml
echo
run_pass "spiffe://homelab/unregistered-agent" "staging" "on"
PASS2_SUMMARY="$PASS_SUMMARY"

# ── Stage 5: Pass 3 -- the golden path ──────────────────────────────────
pause_stage "Pass 3 -- the golden path"
run_pass "spiffe://homelab/deploy-bot" "staging" "on"
GOLDEN_TRACE_ID="$TRACE_ID"
PASS3_SUMMARY="$PASS_SUMMARY"

# ── Stage 6: see the mechanism, live -- not asserted, run ───────────────
pause_stage "See the mechanism"

POLICY_FILE=".demo-state/rendered/kyverno-policy.yaml"
if [[ ! -f "$POLICY_FILE" ]]; then
  render_template k8s/kyverno-policy.yaml "$POLICY_FILE"
fi

ALLOW_MANIFEST=".demo-state/live-check-allow.yaml"
DENY_MANIFEST=".demo-state/live-check-deny.yaml"
mkdir -p .demo-state
TMP_LOGS+=("$ALLOW_MANIFEST" "$DENY_MANIFEST")

cat > "$ALLOW_MANIFEST" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: demo-live-check-allow
  namespace: ${STAGING_NS}
  labels:
    demo.io/synthetic-check: "true"
  annotations:
    demo.io/identity: spiffe://homelab/deploy-bot
    demo.io/scope: staging
    demo.io/tool: get_pod_status
spec:
  containers:
    - name: synthetic-check
      image: busybox:1.36
EOF

cat > "$DENY_MANIFEST" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: demo-live-check-deny
  namespace: ${PROD_NS}
  labels:
    demo.io/synthetic-check: "true"
  annotations:
    demo.io/identity: spiffe://homelab/deploy-bot
    demo.io/scope: staging
    demo.io/tool: get_secret
type: Opaque
stringData:
  placeholder: synthetic-check
EOF

echo
show_and_run kyverno apply "$POLICY_FILE" --resource "$ALLOW_MANIFEST"
echo
show_and_run kyverno apply "$POLICY_FILE" --resource "$DENY_MANIFEST" || true

# ── Stage 7: the recap, and the traces ──────────────────────────────────
pause_stage "See the traces"
echo "Pass 1 (no identity, no policy):"
printf '%s\n' "$PASS1_SUMMARY" | colorize_verdicts | sed 's/^/  /'
echo "Pass 2 (identity, no grant):"
printf '%s\n' "$PASS2_SUMMARY" | colorize_verdicts | sed 's/^/  /'
echo "Pass 3 (golden path):"
printf '%s\n' "$PASS3_SUMMARY" | colorize_verdicts | sed 's/^/  /'
echo
if [[ -n "$GOLDEN_TRACE_ID" ]]; then
  log_info "Pass 3 (golden path) trace : http://${OBS_HOST}:${JAEGER_LOCAL_PORT}/trace/${GOLDEN_TRACE_ID}"
  log_info "  -- green get_pod_status, green get_pod_logs, red get_secret, one trace ID."
else
  log_warn "Could not find pass 3's trace ID -- check the port-forwards and the log above."
fi
log_info "Grafana : http://${OBS_HOST}:${GRAFANA_LOCAL_PORT}  (user: admin / pass: pod-investigator-demo)"

DEMO_END=$(date +%s)
echo
log_info "Total demo runtime: $((DEMO_END - DEMO_START))s (budget: 6-8 min)."
