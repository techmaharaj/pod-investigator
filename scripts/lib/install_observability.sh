#!/usr/bin/env bash
# Installs a dedicated, throwaway Jaeger + OTel Collector + Grafana into
# ${OBS_NS}. Sized conservatively for a resource-constrained homelab node.
# Fully namespace-scoped -- no cluster-wide resources, teardown just
# deletes the namespace.
#
# Chart versions are pinned (not "latest") for reproducibility. Charts are
# downloaded to a local .tgz via download_with_github_fallback (see
# common.sh) and installed from that local file rather than letting helm
# fetch the release asset itself -- helm's Go HTTP client has no
# equivalent of curl's --resolve, so it can't work around the same
# github.com DNS flakiness kyverno_cli_bootstrap.sh routes around.

JAEGER_CHART_VERSION="4.0.0"       # -> Jaeger v1.53.0 (allInOne-style values)
OTEL_COLLECTOR_CHART_VERSION="0.170.0"
GRAFANA_CHART_VERSION="10.5.15"

install_observability() {
  helm repo add jaegertracing https://jaegertracing.github.io/helm-charts >/dev/null
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
  helm repo update jaegertracing open-telemetry grafana >/dev/null

  local charts_dir
  charts_dir="$(repo_root)/.demo-state/charts"
  mkdir -p "$charts_dir"

  log_info "fetching Jaeger chart ${JAEGER_CHART_VERSION}"
  local jaeger_tgz="$charts_dir/jaeger-${JAEGER_CHART_VERSION}.tgz"
  download_with_github_fallback \
    "https://github.com/jaegertracing/helm-charts/releases/download/jaeger-${JAEGER_CHART_VERSION}/jaeger-${JAEGER_CHART_VERSION}.tgz" \
    "$jaeger_tgz" || { log_error "failed to fetch jaeger chart"; exit 1; }

  log_info "fetching OTel Collector chart ${OTEL_COLLECTOR_CHART_VERSION}"
  local otel_tgz="$charts_dir/opentelemetry-collector-${OTEL_COLLECTOR_CHART_VERSION}.tgz"
  download_with_github_fallback \
    "https://github.com/open-telemetry/opentelemetry-helm-charts/releases/download/opentelemetry-collector-${OTEL_COLLECTOR_CHART_VERSION}/opentelemetry-collector-${OTEL_COLLECTOR_CHART_VERSION}.tgz" \
    "$otel_tgz" || { log_error "failed to fetch opentelemetry-collector chart"; exit 1; }

  log_info "fetching Grafana chart ${GRAFANA_CHART_VERSION}"
  local grafana_tgz="$charts_dir/grafana-${GRAFANA_CHART_VERSION}.tgz"
  download_with_github_fallback \
    "https://github.com/grafana/helm-charts/releases/download/grafana-${GRAFANA_CHART_VERSION}/grafana-${GRAFANA_CHART_VERSION}.tgz" \
    "$grafana_tgz" || { log_error "failed to fetch grafana chart"; exit 1; }

  log_info "installing Jaeger (all-in-one, in-memory storage)"
  helm upgrade --install jaeger "$jaeger_tgz" \
    --kube-context "$KUBE_CTX" \
    --namespace "$OBS_NS" \
    --values "$(repo_root)/k8s/observability/jaeger-values.yaml" \
    --wait --timeout 3m

  log_info "installing OTel Collector"
  helm upgrade --install otel-collector "$otel_tgz" \
    --kube-context "$KUBE_CTX" \
    --namespace "$OBS_NS" \
    --values "$(repo_root)/k8s/observability/otel-collector-values.yaml" \
    --wait --timeout 3m

  log_info "installing Grafana"
  helm upgrade --install grafana "$grafana_tgz" \
    --kube-context "$KUBE_CTX" \
    --namespace "$OBS_NS" \
    --values "$(repo_root)/k8s/observability/grafana-values.yaml" \
    --wait --timeout 3m

  log_info "observability stack installed in namespace $OBS_NS"
}
