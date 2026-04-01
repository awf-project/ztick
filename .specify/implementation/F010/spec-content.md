# F010: Add OpenTelemetry Instrumentation

## Scope

### In Scope

- OTLP/HTTP JSON exporter for metrics, traces, and structured logs using stdlib only
- Metric instrumentation: counters, gauges, and histograms for job lifecycle, connections, and persistence
- Trace instrumentation: spans for TCP request lifecycle and job execution
- Structured log export via OTLP alongside metrics and traces
- `[telemetry]` configuration section with opt-in enable, endpoint, service name, and flush interval
- Batch export with periodic flush and flush-on-shutdown
- Thread-safe atomic counters and dedicated exporter thread

### Out of Scope

- gRPC transport — not yet supported in Zig's ecosystem
- Prometheus `/metrics` pull endpoint (future HTTP controller concern)
- Distributed trace context propagation across network boundaries (only internal thread propagation)
- Dynamic histogram bucket configuration

### Deferred

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| Prometheus pull endpoint | Requires HTTP controller infrastructure not yet built | future |
| gRPC/protobuf OTLP transport | Violates zero-dependency constraint; JSON sufficient for initial release | future |
| Custom histogram bucket configuration | Fixed buckets cover ztick's execution latency range; configurability adds complexity without clear need | future |
| Trace sampling configuration | At ztick's expected request volume, 100% sampling is viable; sampling adds complexity | future |
| Log level filtering for OTLP export | Startup logging feature not yet landed; dual-routing design deferred until log infrastructure matures | future |

---

## User Stories

### US1: Export Metrics to OpenTelemetry Collector (P1 - Must Have)

**As a** ztick operator,
**I want** ztick to export job throughput, execution latency, error rates, and connection counts as OTLP metrics to my collector,
**So that** I can monitor ztick's health and performance in my existing observability stack (Grafana, Datadog, etc.) without manual inspection.

**Why this priority**: Metrics are the most immediately actionable signal — they power dashboards, alerts, and SLA monitoring. Without metrics, operators are blind to ztick's runtime behavior.

**Acceptance Scenarios:**
1. **Given** telemetry is enabled with a valid endpoint, **When** a job is scheduled via SET, **Then** the `ztick.jobs.scheduled` counter increments by 1 and is included in the next OTLP batch export.
2. **Given** telemetry is enabled, **When** a job executes successfully, **Then** `ztick.jobs.executed` increments with label `success=true` and `ztick.execution.duration_ms` records the execution time in the appropriate histogram bucket.
3. **Given** telemetry is enabled, **When** a job execution fails, **Then** `ztick.jobs.executed` increments with label `success=false`.
4. **Given** telemetry is enabled, **When** a TCP client connects and disconnects, **Then** `ztick.connections.active` gauge increments on connect and decrements on disconnect.
5. **Given** telemetry is disabled (default), **When** ztick runs normally, **Then** no HTTP requests are made to any telemetry endpoint, no additional allocations occur, and no exporter thread is spawned.

**Independent Test:** Start ztick with telemetry enabled pointing at a mock HTTP server. Send SET, REMOVE, and RULE SET commands. Verify the mock server receives OTLP JSON payloads at `/v1/metrics` containing the expected counter and gauge values.

### US2: Export Request and Execution Traces (P2 - Should Have)

**As a** ztick operator debugging a slow or failed job,
**I want** ztick to emit traces with spans covering the full request lifecycle (TCP receive → parse → dispatch → response) and job execution lifecycle (trigger → runner invocation → exit code → response routing),
**So that** I can pinpoint latency bottlenecks and failure points in my tracing backend.

**Why this priority**: Traces provide the "why" behind metric anomalies. They are essential for debugging but less critical than metrics for basic monitoring, making them a strong P2.

**Acceptance Scenarios:**
1. **Given** telemetry is enabled, **When** a SET instruction is received over TCP, **Then** a trace is created with a span covering instruction parse through scheduler dispatch, and exported via OTLP to `/v1/traces`.
2. **Given** telemetry is enabled, **When** a scheduled job fires and the runner executes, **Then** a span records the runner type, execution duration, and exit code as span attributes.
3. **Given** telemetry is enabled, **When** a request span and its corresponding execution span belong to the same job, **Then** both spans share the same trace ID, enabling end-to-end trace reconstruction.

**Independent Test:** Start ztick with telemetry enabled. Schedule a job via SET with a near-future timestamp. Wait for execution. Verify the mock collector receives trace payloads with correlated spans containing expected attributes.

### US3: Configure Telemetry via TOML (P1 - Must Have)

**As a** ztick operator,
**I want** to configure telemetry settings (enabled, endpoint, service name, flush interval) in the existing TOML config file,
**So that** I can control telemetry behavior without code changes or environment variables.

**Why this priority**: Configuration is a prerequisite for all telemetry functionality — without it, no other user story is usable.

**Acceptance Scenarios:**
1. **Given** no `[telemetry]` section in config, **When** ztick starts, **Then** telemetry is disabled by default with no errors.
2. **Given** a config with `[telemetry]` section containing `enabled = true` and `endpoint = "http://collector:4318"`, **When** ztick starts, **Then** telemetry initializes and exports to the specified endpoint.
3. **Given** a config with an invalid telemetry key (e.g., `[telemetry] unknown_key = true`), **When** ztick starts, **Then** it exits with a ConfigError identifying the invalid key.
4. **Given** a config with `flush_interval_ms = 10000`, **When** ztick runs, **Then** OTLP batches are flushed approximately every 10 seconds.

**Independent Test:** Create config files with various `[telemetry]` permutations. Parse each and verify the resulting Config struct contains correct values or returns appropriate errors.

### US4: Export Structured Logs via OTLP (P3 - Nice to Have)

**As a** ztick operator,
**I want** ztick's log records forwarded via OTLP to my centralized logging system,
**So that** I can correlate logs with metrics and traces in a single observability platform.

**Why this priority**: Log export provides completeness to the three-signal observability story but is least critical — operators can still access logs via stdout/journald. This also benefits from the not-yet-implemented startup logging feature.

**Acceptance Scenarios:**
1. **Given** telemetry is enabled, **When** ztick emits a log record at warn level or above, **Then** the log record is batched and exported via OTLP to `/v1/logs` with severity, timestamp, and message body.

**Independent Test:** Start ztick with telemetry enabled and trigger a warning-level log event. Verify the mock collector receives an OTLP log payload with correct severity mapping.

### Edge Cases

- What happens when the OTLP collector endpoint is unreachable? System must continue operating normally; export failures must not block the scheduler tick loop or TCP server.
- What happens when the export buffer fills up (collector down for extended period)? Oldest records must be dropped to bound memory usage; a warning must be logged.
- What happens when telemetry is enabled but the endpoint is malformed? Config parsing must reject invalid URLs at startup with a clear error message.
- What happens during shutdown with pending unexported records? System must attempt a final flush with a bounded timeout before exiting.
- What happens when metric counters overflow? Counters must use wrapping arithmetic or saturating addition to avoid undefined behavior.

---

## Requirements

### Functional Requirements

- **FR-001**: System MUST export metrics via OTLP/HTTP JSON to a configurable endpoint at `/v1/metrics`.
- **FR-002**: System MUST track these metrics: `ztick.jobs.scheduled` (counter), `ztick.jobs.executed` (counter with `success` label), `ztick.jobs.removed` (counter), `ztick.rules.active` (gauge), `ztick.execution.duration_ms` (histogram), `ztick.connections.active` (gauge), `ztick.persistence.compactions` (counter).
- **FR-003**: System MUST export traces via OTLP/HTTP JSON to `/v1/traces` with spans for TCP request lifecycle and job execution lifecycle.
- **FR-004**: System MUST propagate trace context between controller, database, and processor threads so spans within a single request share a trace ID.
- **FR-005**: System MUST export structured log records via OTLP/HTTP JSON to `/v1/logs`.
- **FR-006**: System MUST parse a `[telemetry]` config section with keys: `enabled` (bool), `endpoint` (string), `service_name` (string), `flush_interval_ms` (u32).
- **FR-007**: System MUST disable telemetry by default when no `[telemetry]` section is present.
- **FR-008**: System MUST reject unknown keys in the `[telemetry]` section with a ConfigError.
- **FR-009**: System MUST batch export records and flush at the configured interval.
- **FR-010**: System MUST flush pending records on shutdown with a bounded timeout.
- **FR-011**: System MUST attach `service.name`, `service.version`, and `host.name` resource attributes to all exported signals.
- **FR-012**: System MUST use fixed-bucket histograms with boundaries at 1, 5, 10, 50, 100, 500, 1000, 5000, 30000 milliseconds.

### Non-Functional Requirements

- **NFR-001**: When telemetry is disabled, instrumentation calls MUST have zero overhead — no allocations, no atomic operations, no thread spawning.
- **NFR-002**: Metric updates (counter increment, gauge set, histogram record) MUST NOT block the scheduler tick loop or TCP accept loop.
- **NFR-003**: OTLP export failures MUST NOT cause ztick to crash, hang, or degrade core scheduling functionality.
- **NFR-004**: Export buffer memory MUST be bounded; when full, oldest records are dropped.
- **NFR-005**: Implementation MUST use zig-o11y/opentelemetry-sdk for OTLP serialization and export (ADR-0004).
- **NFR-006**: Telemetry exporter thread MUST respect the existing shutdown coordination pattern (atomic flag + channel close + thread join).

---

## Success Criteria

- **SC-001**: Operators can view ztick job throughput, error rates, and execution latency on a collector-connected dashboard within 2 flush intervals of events occurring.
- **SC-002**: Operators can trace a single TCP request end-to-end from receipt through execution completion using correlated span IDs in their tracing backend.
- **SC-003**: Disabling telemetry produces zero measurable overhead — no difference in scheduler tick rate or TCP throughput compared to a build without telemetry code.
- **SC-004**: Ztick continues operating at full capacity when the OTLP collector is unreachable for 60+ seconds, with automatic export resumption when the collector recovers.
- **SC-005**: All 7 defined metrics are correctly exported and visible in an OpenTelemetry-compatible collector within one integration test run.

---

## Key Entities

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| MetricRegistry | Central store for all metric instruments | counters (atomic u64), gauges (atomic i64), histograms (bucket counts + sum) |
| Span | Represents a unit of work with timing and attributes | trace_id, span_id, parent_span_id, name, start_time_ns, end_time_ns, attributes, status |
| TraceContext | Propagates trace identity across thread boundaries | trace_id, span_id (passed via channel messages) |
| LogRecord | Structured log entry for OTLP export | timestamp_ns, severity, body, resource_attributes |
| ExportBatch | Buffered collection of records awaiting flush | metrics, spans, log_records, record_count, byte_estimate |
| TelemetryConfig | Parsed `[telemetry]` section values | enabled, endpoint, service_name, flush_interval_ms |

---

## Assumptions

- The OTLP collector accepts payloads per the OpenTelemetry specification (OTLP/HTTP).
- zig-o11y/opentelemetry-sdk v0.1.1 provides stable OTLP export for Zig 0.15.2.
- Fixed histogram buckets (1ms–30s) adequately cover ztick's job execution latency distribution.
- At ztick's expected request volume, 100% trace sampling is acceptable without configurable sampling.
- The three-thread architecture (controller, database, processor) remains stable — telemetry hooks into existing thread boundaries.
- Operators have an OpenTelemetry-compatible collector (e.g., otel-collector, Grafana Agent, Datadog Agent) deployed and reachable from the ztick host.

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: low
- **Estimation**: XL

## Dependencies

- **Blocked by**: none
- **Unblocks**: none

## Clarifications

_Section populated during clarify step with resolved ambiguities._

## Notes

- OTLP/HTTP endpoints: `POST /v1/metrics`, `POST /v1/traces`, `POST /v1/logs`.
- Uses zig-o11y/opentelemetry-sdk (ADR-0004) for OTLP serialization, export, and instrument management. SDK provides MeterProvider, TracerProvider, LoggerProvider, and std.log bridge.
- Consider incremental delivery: metrics first (US1 + US3), then traces (US2), then logs (US4).
- Histogram implementation uses fixed buckets [1,5,10,50,100,500,1000,5000,30000]ms.
- Thread safety handled by SDK's atomic instruments and batching processors.
