#!/usr/bin/env bash
# Ensures the `kyverno` CLI is available. This CLI is what evaluates the
# ClusterPolicy against synthetic per-tool-call manifests -- the same policy
# engine and YAML the live admission webhook uses, just invoked as a local
# dry-run instead of a real AdmissionReview (real K8s admission control
# can't intercept reads like get_pod_logs/get_secret, only writes -- see
# the README for why this is the honest approach).

KYVERNO_CLI_VERSION="v1.13.2"
LOCAL_BIN_DIR="$(repo_root)/.demo-state/bin"

bootstrap_kyverno_cli() {
  if command -v kyverno >/dev/null 2>&1; then
    log_info "kyverno CLI already on PATH: $(command -v kyverno)"
    return 0
  fi

  if [[ -x "$LOCAL_BIN_DIR/kyverno" ]]; then
    log_info "kyverno CLI already downloaded at $LOCAL_BIN_DIR/kyverno"
    export PATH="$LOCAL_BIN_DIR:$PATH"
    return 0
  fi

  local os arch
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *) log_error "unsupported OS for kyverno CLI auto-download: $(uname -s)"; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) log_error "unsupported architecture for kyverno CLI auto-download: $(uname -m)"; exit 1 ;;
  esac

  local asset="kyverno-cli_${KYVERNO_CLI_VERSION}_${os}_${arch}.tar.gz"
  local url="https://github.com/kyverno/kyverno/releases/download/${KYVERNO_CLI_VERSION}/${asset}"

  log_info "downloading kyverno CLI ${KYVERNO_CLI_VERSION} (${os}/${arch})"
  mkdir -p "$LOCAL_BIN_DIR"
  local tmp_tar="$LOCAL_BIN_DIR/kyverno.tar.gz"

  if ! download_with_github_fallback "$url" "$tmp_tar"; then
    log_error "failed to download $url (including via GitHub IP fallback)"
    log_error "install the kyverno CLI manually (https://github.com/kyverno/kyverno/releases) and re-run"
    exit 1
  fi
  tar -xzf "$tmp_tar" -C "$LOCAL_BIN_DIR" kyverno
  rm -f "$tmp_tar"
  chmod +x "$LOCAL_BIN_DIR/kyverno"
  export PATH="$LOCAL_BIN_DIR:$PATH"
  log_info "kyverno CLI installed at $LOCAL_BIN_DIR/kyverno"
}
