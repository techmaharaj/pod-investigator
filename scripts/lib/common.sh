#!/usr/bin/env bash
# Shared logging + helper functions. Sourced by setup.sh / teardown.sh and
# every scripts/lib/*.sh file -- never executed directly.

COLOR_RESET='\033[0m'
COLOR_BLUE='\033[34m'
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_RED='\033[31m'
COLOR_BOLD='\033[1m'

log_step()  { printf "${COLOR_BOLD}${COLOR_BLUE}==> %s${COLOR_RESET}\n" "$*"; }
log_info()  { printf "${COLOR_GREEN}[info]${COLOR_RESET} %s\n" "$*"; }
log_warn()  { printf "${COLOR_YELLOW}[warn]${COLOR_RESET} %s\n" "$*"; }
log_error() { printf "${COLOR_RED}[error]${COLOR_RESET} %s\n" "$*" >&2; }

# confirm "question text" -> returns 0 only if the user types the literal
# word 'yes'. Used before every cluster-wide or destructive action.
confirm() {
  local prompt="$1" reply
  read -r -p "$(printf "${COLOR_YELLOW}%s [type 'yes' to continue]: ${COLOR_RESET}" "$prompt")" reply
  [[ "$reply" == "yes" ]]
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "required command not found: $cmd"
    return 1
  fi
}

# render_template <src-file> <dest-file>
# Minimal, dependency-free templating (plain sed) so k8s manifests and helm
# values can reference ${NAMESPACE_PREFIX}/${STAGING_NS}/${PROD_NS}/${OBS_NS}
# without requiring envsubst to be installed.
render_template() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  sed \
    -e "s#\${NAMESPACE_PREFIX}#${NAMESPACE_PREFIX}#g" \
    -e "s#\${STAGING_NS}#${STAGING_NS}#g" \
    -e "s#\${PROD_NS}#${PROD_NS}#g" \
    -e "s#\${OBS_NS}#${OBS_NS}#g" \
    "$src" > "$dest"
}

# Resolve repo root regardless of caller's cwd.
repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# download_with_github_fallback <url> <dest>
# Some resolvers (seen in the wild on Tailscale MagicDNS) intermittently
# fail to resolve the github.com apex specifically while resolving
# everything else fine. Try normally first, then retry against a short
# list of known-stable GitHub IPs rather than failing over what's usually
# a transient DNS quirk outside this repo's control.
download_with_github_fallback() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"

  if curl -fsSL -o "$dest" "$url" 2>/dev/null; then
    return 0
  fi

  if [[ "$url" != *"github.com"* ]]; then
    return 1
  fi

  log_warn "DNS resolution for github.com failed -- retrying against known GitHub IPs"
  local fallback_ips=(140.82.113.3 140.82.114.3 140.82.121.3 140.82.112.3)
  local ip
  for ip in "${fallback_ips[@]}"; do
    if curl -fsSL --resolve "github.com:443:${ip}" -o "$dest" "$url" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}
