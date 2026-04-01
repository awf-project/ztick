# Implementation Plan: F010

## Summary

Add OpenTelemetry instrumentation to ztick using zig-o11y/opentelemetry-sdk (ADR-0004). The SDK provides MeterProvider, TracerProvider, LoggerProvider, OTLP exporters, and std.log bridge. The implementation adds a `[telemetry]` config section in interfaces, instrument wiring in the application layer (scheduler, tcp_server), SDK provider setup in main.zig, and a thin infrastructure adapter for SDK initialization.

## Constitution Compliance

Constitution: Derived from CLAUDE.md

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal layering (domain → application → infrastructure → interfaces) | COMPLIANT | SDK usage isolated in infrastructure; application layer uses SDK API types (Counter, Histogram, Gauge); domain untouched |
| Minimal dependencies | COMPLIANT | zig-o11y/opentelemetry-sdk justified by ADR-0004; standardized protocol, community-backed |
| Tagged unions with struct payloads | COMPLIANT | No new tagged unions needed; existing patterns preserved |
| Barrel exports per layer | COMPLIANT | New modules added to application.zig and infrastructure.zig barrels |
| Process.execute() for background operations | N/A | SDK manages its own exporter threads via BatchingProcessor/PeriodicReader |
| Atomic rename pattern for persistence | N/A | No persistence writes in telemetry |
| Per-connection response channels | N/A | Telemetry has no per-connection state |
| Co-located unit tests | COMPLIANT | Tests in same .zig files with verbose behavioral naming |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.15.2 |
| Framework | zig-o11y/opentelemetry-sdk v0.1.1 (ADR-0004) |
| Architecture | Hexagonal (4 layers: domain, application, infrastructure, interfaces) |
| Key patterns | SDK MeterProvider/TracerProvider/LoggerProvider, SDK OTLP exporters (HTTP JSON/protobuf), SDK std.log bridge, config section parsing with UnknownKey rejection |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | How does the disabled telemetry path avoid overhead? | SDK providers default to noop when not initialized. When telemetry is disabled, no providers are created, no instruments allocate, no exporter threads spawn. Application code uses SDK API types directly — noop providers make all calls zero-cost. | SDK design: noop default providers; pattern from `self.persistence orelse return` in scheduler.zig:159 |
| A2 | How should the exporter thread lifecycle work? | SDK manages exporter threads internally via BatchingProcessor (traces/logs) and PeriodicExportingReader (metrics). Shutdown via SDK's provider.shutdown() which handles flush + join. | SDK provides thread lifecycle management; no manual Thread.spawn needed |
| A3 | How to serialize OTLP? | SDK handles all serialization (protobuf + JSON) and HTTP transport via its OTLP exporters. No manual serialization needed. | SDK OtlpTraceExporter, OtlpMetricExporter, OtlpLogExporter |
| A4 | Where do metric updates happen in the tick loop? | In TickContext.tick() in main.zig and Scheduler methods. SDK Counter/Histogram/Gauge instruments are passed to Scheduler and TickContext. | main.zig:188-210 TickContext struct and tick function |
| A5 | How does the scheduler access instruments without domain layer contamination? | SDK API types (Counter, Histogram, Gauge) passed via TickContext and optional fields on Scheduler, following the persistence pattern. Domain layer remains pure — no SDK imports. | scheduler.zig:22-23 persistence field pattern |
| A6 | How to handle endpoint string ownership in config? | Allocator.dupe in parse(), free in Config.deinit(), matching controller_listen pattern. Endpoint passed to SDK OtlpExporter config at initialization. | config.zig:47-48,91-92 controller_listen alloc/free pattern |

## Approach Comparison

| Criteria | Approach A: zig-o11y/opentelemetry-sdk | Approach B: Hand-rolled stdlib-only | Approach C: File-based export |
|----------|----------------------------------------|-------------------------------------|-------------------------------|
| Description | Use community SDK for instruments, exporters, serialization. Wire SDK types into scheduler/tcp_server. | Hand-roll MetricRegistry, OTLP JSON serializer, exporter thread, span model | Write OTLP JSON to local file, external tool ships |
| Files touched | 4-5 new/modified | 6-8 new/modified | 3-4 new/modified |
| New abstractions | 0 (SDK provides all) | 2 (MetricRegistry, OtlpExporter) | 1 (OtlpFileWriter) |
| Risk level | Low | Med | Low |
| Reversibility | Easy (swap SDK) | Hard (custom protocol impl) | Easy |

**Selected: Approach A**
**Rationale:** SDK provides spec-compliant OTLP export, thread-safe instruments, batching processors, and std.log bridge. Eliminates ~60% of implementation tasks compared to hand-rolling. NFR-002 (non-blocking) satisfied by SDK's atomic instruments and background batching. ADR-0004 justifies the dependency.
**Trade-off accepted:** First Zig package dependency; 3 transitive deps. Justified by protocol complexity and community backing.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| zig-o11y/opentelemetry-sdk over hand-rolled | Spec-compliant OTLP, community-backed, eliminates ~60% of tasks. ADR-0004. | Hand-rolled stdlib-only — high cost, spec-conformance risk, duplicates solved problems |
| SDK noop providers for disabled path | SDK defaults to noop when providers not initialized — zero overhead without custom null-check code | Custom `?*MetricRegistry` null pattern — unnecessary with SDK noop defaults |
| SDK-managed exporter threads | SDK's BatchingProcessor and PeriodicReader manage background threads and flush lifecycle | Manual Thread.spawn + atomic flag — SDK does this better, less code to maintain |
| SDK instruments passed to application layer | Counter/Histogram/Gauge are SDK API types, passed as fields on Scheduler/TickContext. Thin dependency, easily mockable. | Wrapping SDK types in custom interfaces — premature abstraction |
| Fixed histogram buckets [1,5,10,50,100,500,1000,5000,30000]ms | Spec says fixed buckets; configured via SDK Histogram options | Dynamic bucket allocation — spec explicitly defers configurability |
| Incremental delivery: metrics → traces → logs | Spec recommends incremental. Metrics are P1, traces P2, logs P3. | Build everything at once — higher risk, harder to test incrementally |

## Components

```json
[
  {
    "name": "sdk_dependency",
    "project": "",
    "layer": "infrastructure",
    "description": "Add zig-o11y/opentelemetry-sdk v0.1.1 to build.zig.zon. Configure build.zig to expose SDK module. Create infrastructure/telemetry.zig barrel with SDK initialization helpers.",
    "files": ["build.zig.zon", "build.zig", "src/infrastructure/telemetry.zig", "src/infrastructure.zig"],
    "tests": [],
    "dependencies": [],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build",
      "expected_output": "Build succeeds",
      "build_command": "zig build"
    }
  },
  {
    "name": "telemetry_config",
    "project": "",
    "layer": "interfaces",
    "description": "Parse [telemetry] config section with enabled, endpoint, service_name, flush_interval_ms keys. Defaults: disabled, no endpoint, 'ztick' service name, 5000ms flush interval.",
    "files": ["src/interfaces/config.zig"],
    "tests": ["src/interfaces/config.zig"],
    "dependencies": [],
    "user_story": "US3",
    "verification": {
      "test_command": "zig build test-interfaces",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "sdk_provider_setup",
    "project": "",
    "layer": "infrastructure",
    "description": "Initialize SDK MeterProvider, TracerProvider, LoggerProvider with OTLP exporters in infrastructure/telemetry.zig. Configure endpoint, service_name, flush_interval from TelemetryConfig. Provide setup/shutdown functions. Wire std.log bridge for OTLP log export.",
    "files": ["src/infrastructure/telemetry.zig"],
    "tests": ["src/infrastructure/telemetry.zig"],
    "dependencies": ["sdk_dependency", "telemetry_config"],
    "user_story": "US1,US4",
    "verification": {
      "test_command": "zig build test-infrastructure",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "scheduler_instrumentation",
    "project": "",
    "layer": "application",
    "description": "Wire SDK instruments (Counter, Histogram, Gauge) into Scheduler and TickContext. Increment ztick.jobs.scheduled on SET, ztick.jobs.removed on REMOVE, ztick.jobs.executed on execution result, record ztick.execution.duration_ms histogram, update ztick.rules.active gauge, increment ztick.persistence.compactions on compression.",
    "files": ["src/application/scheduler.zig", "src/main.zig"],
    "tests": ["src/application/scheduler.zig"],
    "dependencies": ["sdk_provider_setup"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-application",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "trace_instrumentation",
    "project": "",
    "layer": "application",
    "description": "Add SDK Tracer spans to TCP request lifecycle and job execution lifecycle. Propagate trace context via TickContext. Correlated trace IDs between request and execution spans.",
    "files": ["src/application/scheduler.zig", "src/main.zig"],
    "tests": ["src/application/scheduler.zig"],
    "dependencies": ["scheduler_instrumentation"],
    "user_story": "US2",
    "verification": {
      "test_command": "zig build test-application",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "main_wiring",
    "project": "",
    "layer": "interfaces",
    "description": "Wire telemetry into main.zig: call SDK provider setup when telemetry enabled (noop when disabled), pass instruments to Scheduler/TickContext, pass connections_active gauge to TCP server, call SDK shutdown in shutdown sequence.",
    "files": ["src/main.zig"],
    "tests": [],
    "dependencies": ["scheduler_instrumentation", "trace_instrumentation", "sdk_provider_setup"],
    "user_story": "US1,US3",
    "verification": {
      "test_command": "zig build test",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  }
]
```

## Test Plan

### Unit Tests

**telemetry_config (interfaces/config.zig):**
- `parse defaults telemetry to disabled when section absent` — verify enabled=false, endpoint=null
- `parse enables telemetry with endpoint from config` — enabled=true, endpoint set
- `parse sets telemetry service name from config` — custom service_name
- `parse sets telemetry flush interval from config` — custom flush_interval_ms
- `parse rejects unknown key in telemetry section` — UnknownKey error
- `parse rejects telemetry enabled without endpoint` — InvalidValue error
- `parse rejects malformed endpoint` — InvalidValue error
- `parse defaults telemetry service name to ztick` — default service_name
- `parse defaults telemetry flush interval to 5000` — default flush_interval_ms

**sdk_provider_setup (infrastructure/telemetry.zig):**
- `setup returns providers with OTLP exporters configured` — provider initialization
- `setup with disabled config returns null providers` — noop path
- `shutdown flushes and cleans up providers` — graceful shutdown

**scheduler_instrumentation (application/scheduler.zig):**
- `handle_query SET increments jobs_scheduled counter` — counter wired
- `handle_query REMOVE increments jobs_removed counter` — counter wired
- `tick increments jobs_executed counter on execution result` — counter with success/failure
- `tick records execution duration in histogram` — histogram wired
- `compression completion increments compactions counter` — counter wired
- `scheduler with null instruments performs no metric operations` — zero-overhead path

**trace_instrumentation (application/scheduler.zig):**
- `SET request creates request span` — span wired
- `job execution creates execution span with runner_type attribute` — span attributes
- `request and execution spans share same trace_id` — trace correlation

### Functional Tests

- `telemetry disabled by default produces no exporter thread` — NFR-001 zero overhead
- `telemetry enabled exports metrics to collector endpoint` — end-to-end US1

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| SDK alpha API breaking changes | Med | P1 | Pin to exact v0.1.1 tag; SDK usage isolated in infrastructure/telemetry.zig for easy adaptation | Developer |
| SDK transitive dependency issues (zig-protobuf, zlib) | Low | P1 | All deps fetched via URL+hash; zlib slated for removal in Zig 0.16 (stdlib deflate) | Developer |
| OTLP format mismatch with collectors | Low | P1 | SDK follows OTel spec; community-tested against standard collectors | Developer |
| Metric overhead on hot path (tick loop) | Low | P2 | SDK instruments use atomic operations (~5ns); noop when disabled | Developer |
| Histogram bucket boundaries don't match real latency distribution | Low | P2 | Fixed buckets [1,5,10,50,100,500,1000,5000,30000]ms cover spec's expected range | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| `TcpServer.active_connections` | Becomes redundant once `ztick.connections.active` gauge tracks same value | Consolidate to use registry gauge; remove standalone atomic (in future PR, not this feature) |

