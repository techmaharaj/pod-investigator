# OTel SDK init + span helpers. Every tool call gets a `mcp.tool.<name>`
# span carrying gen_ai.* (tool name, provider, derived from LLM_MODEL) and
# policy.* (decision, reason) attributes, exported as OTLP to the in-cluster
# collector -- reached over the same port-forward pattern as Grafana/Jaeger
# (see scripts/lib/start_port_forward.sh).
import os
from contextlib import contextmanager

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import RandomIdGenerator, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import NonRecordingSpan, SpanContext, TraceFlags, set_span_in_context

SERVICE_NAME = "pod-investigator-mcp-server"

_provider: TracerProvider | None = None


def _gen_ai_system() -> str:
    model = os.environ.get("LLM_MODEL", "anthropic/claude-haiku-4-5-20251001")
    return model.split("/", 1)[0] if "/" in model else model


def init_tracing() -> TracerProvider:
    global _provider
    if _provider is not None:
        return _provider

    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
    provider = TracerProvider(resource=Resource.create({"service.name": SERVICE_NAME}))
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=True))
    )
    trace.set_tracer_provider(provider)
    _provider = provider
    return provider


def shutdown_tracing() -> None:
    global _provider
    if _provider is not None:
        _provider.shutdown()
        _provider = None


# agent/trigger.py generates one trace ID per invocation and passes it here
# via AGENT_TRACE_ID (env, since each trigger.py run spawns a fresh copy of
# this server over stdio) so every mcp.tool.* span in one agent run shares a
# single trace -- letting trigger.py print the exact Jaeger URL for it
# without any data needing to flow back from this subprocess.
def _agent_trace_context():
    trace_id_hex = os.environ.get("AGENT_TRACE_ID")
    if not trace_id_hex:
        return None
    try:
        trace_id = int(trace_id_hex, 16)
    except ValueError:
        return None
    span_context = SpanContext(
        trace_id=trace_id,
        span_id=RandomIdGenerator().generate_span_id(),
        is_remote=True,
        trace_flags=TraceFlags(TraceFlags.SAMPLED),
    )
    return set_span_in_context(NonRecordingSpan(span_context))


@contextmanager
def tool_span(tool_name: str, spiffe_id: str, namespace: str):
    init_tracing()
    tracer = trace.get_tracer(SERVICE_NAME)
    with tracer.start_as_current_span(
        f"mcp.tool.{tool_name}", context=_agent_trace_context()
    ) as span:
        span.set_attribute("gen_ai.tool.name", tool_name)
        span.set_attribute("gen_ai.system", _gen_ai_system())
        span.set_attribute("spiffe.id", spiffe_id)
        span.set_attribute("k8s.namespace", namespace)
        yield span


def record_policy_decision(span, decision) -> None:
    span.set_attribute("policy.decision", "allow" if decision.allowed else "deny")
    span.set_attribute("policy.reason", decision.reason)
    span.set_attribute("policy.enforced", decision.enforced)
    # Jaeger/Grafana only render a span red when its OTel status is ERROR --
    # a custom policy.decision tag alone doesn't affect waterfall color.
    # This is the actual green/green/red visual the demo depends on.
    if not decision.allowed:
        span.set_status(trace.Status(trace.StatusCode.ERROR, decision.reason))
