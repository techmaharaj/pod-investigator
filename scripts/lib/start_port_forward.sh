#!/usr/bin/env bash
# Backgrounds `kubectl port-forward` for Grafana + Jaeger, bound to 0.0.0.0
# so they're reachable from other Tailscale-connected devices (not just
# localhost on the cluster host), writes PIDs for teardown, and prints the
# working URLs.

start_port_forward() {
  local state_dir grafana_port jaeger_port otel_port host_ip
  state_dir="$(repo_root)/.demo-state"
  mkdir -p "$state_dir"
  grafana_port="${GRAFANA_LOCAL_PORT:-3000}"
  jaeger_port="${JAEGER_LOCAL_PORT:-16686}"
  otel_port="${OTEL_LOCAL_PORT:-4317}"

  # Best-effort: prefer the Tailscale IP if available, fall back to the
  # first non-loopback IP, fall back to localhost.
  host_ip="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1)"
  if [[ -z "$host_ip" ]]; then
    host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -z "$host_ip" ]] && host_ip="localhost"

  nohup kubectl --context "$KUBE_CTX" -n "$OBS_NS" port-forward svc/grafana \
    --address 0.0.0.0 "${grafana_port}:80" >"$state_dir/grafana-port-forward.log" 2>&1 &
  echo $! > "$state_dir/grafana.pid"

  nohup kubectl --context "$KUBE_CTX" -n "$OBS_NS" port-forward svc/jaeger-query \
    --address 0.0.0.0 "${jaeger_port}:16686" >"$state_dir/jaeger-port-forward.log" 2>&1 &
  echo $! > "$state_dir/jaeger.pid"

  # The MCP server (mcp_server/otel_setup.py) runs as a host process, not
  # in-cluster, so it needs this same port-forward pattern to reach the
  # OTel Collector's OTLP/gRPC receiver.
  nohup kubectl --context "$KUBE_CTX" -n "$OBS_NS" port-forward svc/otel-collector \
    --address 0.0.0.0 "${otel_port}:4317" >"$state_dir/otel-port-forward.log" 2>&1 &
  echo $! > "$state_dir/otel.pid"

  sleep 3

  log_info "Grafana : http://${host_ip}:${grafana_port}  (user: admin / pass: pod-investigator-demo)"
  log_info "Jaeger  : http://${host_ip}:${jaeger_port}"
  log_info "OTLP    : http://${host_ip}:${otel_port}  (grpc, used by mcp_server/otel_setup.py)"
  log_info "port-forward PIDs saved to $state_dir/{grafana,jaeger,otel}.pid -- teardown.sh will stop them"
}
