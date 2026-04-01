# Research: F010 — Add OpenTelemetry Instrumentation

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig |
| Domain | CLI scheduler |
| Task Type | feature |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: F001-F009 are all IMPLEMENTED. The codebase follows strict hexagonal architecture (ADR-0001) with 4 layers: domain → application → infrastructure → interfaces. Key implementation patterns relevant to F010 include:
- **Pattern 57**: Time-based scheduling in tick loop (interval_ns + last_ns comparison)
- **Pattern 58**: Process polling for background work status (?*Process with .status())
- **Pattern 60**: Config seconds-to-nanoseconds conversion at construction
- **Pattern 62**: DatabaseContext as config carrier (set-before-spawn)
- **Pattern 36**: C interop via @cImport (ADR-0003 exception for system libs)
- **Patterns 51-56**: Persistence backend extraction, tagged union method dispatch, config enum with default fallback, variant-gated background work

The F009 architecture analysis (Serena memory) provides detailed struct/function locations, integration patterns, and the exact tick loop flow. The scheduler already has compression scheduling infrastructure (interval_ns, last_compression_ns, active_process) that serves as a template for telemetry flush scheduling.

Claude-mem session #17518 (Mar 31, 10:42 AM) analyzed F010 specification clarifications. No previous F010 implementation work exists — this is greenfield.

**Sources**: feature_roadmap.md, implementation_patterns.md, architecture_decisions.md, Serena memory F009/architecture_analysis, claude-mem #17518
**Recommendation**: Follow established patterns for config extension (F008/F009), background thread spawning (F009 Process pattern), atomic counters (F006 active_connections), and tick-loop scheduling. The 4th exporter thread follows the same spawn-in-main, coordinate-via-atomic-flag-and-channel pattern.

---

### Q1: [ARCH] What patterns should F010 follow?

**Finding**: The codebase uses strict hexagonal architecture with 4 layers, each with barrel exports. F010 code placement:

1. **Domain layer** (`src/domain/`): No telemetry types needed — domain stays pure with zero dependencies.
2. **Application layer** (`src/application/`): Create `telemetry/registry.zig` containing MetricRegistry with atomic counters (u64), gauges (i64), and fixed-bucket histograms. Scheduler calls registry at instrumentation points.
3. **Infrastructure layer** (`src/infrastructure/`): Create `telemetry/exporter.zig` with OTLP/HTTP JSON serialization, batching, and dedicated exporter thread. Thread receives data via Channel(T) and POSTs to collector. Also `telemetry.zig` barrel export.
4. **Interfaces layer** (`src/interfaces/config.zig`): Extend Config to parse `[telemetry]` section (enabled, endpoint, service_name, flush_interval_ms).
5. **Main wiring** (`src/main.zig`): Construct MetricRegistry, spawn exporter thread, wire through TelemetryContext (similar to DatabaseContext pattern). Pass registry to Scheduler.

Three-thread architecture becomes four threads: controller, database, processor, **telemetry exporter**. Shutdown coordination uses existing atomic flag + channel close + thread join pattern.

Key instrumentation points:
- `tcp_server.zig`: Connection accept/close → `ztick.connections.active` gauge (already has atomic active_connections)
- `scheduler.zig handle_query()`: SET → `ztick.jobs.scheduled` counter, REMOVE → `ztick.jobs.removed` counter
- `scheduler.zig tick()`: Execution results → `ztick.jobs.executed` counter (with success label) + `ztick.execution.duration_ms` histogram
- `scheduler.zig maybe_trigger_compression()`: Completion → `ztick.persistence.compactions` counter

**Sources**: src/domain.zig, src/application.zig, src/infrastructure.zig, src/interfaces.zig, src/main.zig:138-220, src/infrastructure/channel.zig, src/infrastructure/tcp_server.zig:79-149, src/application/scheduler.zig:109-141
**Recommendation**: Place MetricRegistry in application layer (business instrumentation concern). Place OTLP exporter in infrastructure layer (HTTP transport concern). Extend config in interfaces layer. Wire in main.zig following DatabaseContext/ProcessorContext pattern.

---

### Q2: [TYPES] Which types can F010 reuse?

**Finding**: 14 key reusable types identified across all layers:

**Domain types (instrument targets):**
- `Job` (src/domain/job.zig:10-14): Lifecycle transitions (planned→triggered→executed/failed) for counters
- `Rule` (src/domain/rule.zig:6-17): Active count for gauge
- `Instruction` (src/domain/instruction.zig:4-27): Command type → metric counter mapping
- `Runner` (src/domain/runner.zig:1-10): Runner type as span attribute
- `ExecutionRequest/Response` (src/domain/execution.zig:4-13): u128 identifier for trace correlation, success bool for labels

**Application types (integration points):**
- `Scheduler` (src/application/scheduler.zig:17-38): Main hook point for metrics — handle_query() and tick()
- `JobStorage` (src/application/job_storage.zig:7-18): count() for active jobs gauge
- `RuleStorage` (src/application/rule_storage.zig:7-15): count() for active rules gauge
- `ExecutionClient` (src/application/execution_client.zig:12-25): trigger() for start, pull_results() for duration histogram

**Infrastructure types (reusable patterns):**
- `TcpServer.active_connections` (src/infrastructure/tcp_server.zig:79): std.atomic.Value(usize) — template for metric atomics
- `Channel(T)` (src/infrastructure/channel.zig:3-99): Bounded queue for sending batches to exporter thread
- `Clock` (src/infrastructure/clock.zig:3-18): Background periodic callback pattern for flush timer
- `Process` (src/infrastructure/persistence/background.zig:14-44): Async task pattern for exporter thread
- `ResponseRouter` (src/infrastructure/tcp_server.zig:37-74): Mutex-protected map pattern

**Interfaces types (extension point):**
- `Config` (src/interfaces/config.zig:25-43): Add telemetry fields; parser at lines 45-143

**Sources**: All source files listed above
**Recommendation**: Reuse std.atomic.Value for zero-overhead metric counters/gauges. Reuse Channel(T) for exporter communication. Follow Clock pattern for periodic flush. Extend Config struct for [telemetry] section. Do NOT add telemetry imports to domain layer.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Testing patterns established across the codebase:

1. **Co-located unit tests**: Tests live in same `.zig` file via `test "descriptive behavior"` blocks. Use `std.testing.allocator` for simple cases, `std.heap.GeneralPurposeAllocator` for complex scenarios with leak assertion via `gpa.deinit()`.

2. **Config parsing tests** (src/interfaces/config.zig:164-362): 18 test cases covering defaults, valid overrides, error paths (expectError for InvalidValue, UnknownKey, FramerateOutOfRange). F010 must add tests for [telemetry] section parsing, defaults when absent, invalid keys, malformed endpoints.

3. **Scheduler tests** (src/application/scheduler.zig:198-400): State transition testing — create Scheduler, configure via handle_query, advance time via tick(), verify state with expectEqual. F010 metric tests follow same pattern: call handle_query(SET), verify counter incremented.

4. **Channel/threading tests** (src/infrastructure/channel.zig:130-150): Use std.Thread.spawn with anonymous struct functions. F010 exporter thread tests can verify message delivery through channel.

5. **Functional tests** (src/functional_tests.zig): Helper functions like build_logfile_bytes(), replay_into_scheduler(). F010 needs helpers for mock HTTP collector and telemetry config setup.

6. **Build targets**: Per-layer test steps (test-domain, test-application, test-infrastructure, test-interfaces, test-functional, test-all). F010 tests register in appropriate layer targets.

7. **Verbose naming**: "tick marks job as executed after successful execution result", "parse rejects unknown key in section"

8. **Resource cleanup**: `defer storage.deinit()`, `defer cfg.deinit(allocator)`, `defer tmp.cleanup()` — mandatory pattern.

**Sources**: src/interfaces/config.zig:164-362, src/application/scheduler.zig:198-400, src/infrastructure/channel.zig:130-150, src/functional_tests.zig, build.zig:40-91
**Recommendation**: Co-locate MetricRegistry tests in registry.zig, exporter tests in exporter.zig, config tests in config.zig. Add functional test for end-to-end telemetry flow (schedule job → verify metric batch). Test zero-overhead when telemetry disabled (no allocations, no atomics, no thread spawn).

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: Historical context from git history, ADRs, and prior research:

1. **Config evolution**: F006 added TLS cert/key pair validation, F008 added persistence mode enum, F009 added compression_interval. F010 follows same extension pattern for [telemetry] section. Config parser in interfaces/config.zig is well-tested and extensible.

2. **Threading model**: Strict 3-thread architecture (controller, database, processor) with atomic flag + channel IPC. F010 adds 4th exporter thread — first expansion of thread count since initial design. Must follow same shutdown coordination pattern.

3. **No HTTP client usage exists**: std.http.Client is available in Zig stdlib but completely unused in codebase. F010 is the first feature requiring HTTP POST. This is uncharted territory — no existing patterns to follow for HTTP error handling, connection management, or retry logic.

4. **JSON generation pattern**: Manual writeAll/writeByte pattern in dump.zig (lines 39-95) for entry serialization. Avoids allocations by using writer interface directly. F010 should follow same pattern for OTLP JSON bodies — no std.json, no intermediate buffers.

5. **Atomic patterns established**: std.atomic.Value(T) used for running flag (bool), active_connections (usize). F010 extends with u64 counters, i64 gauges, histogram bucket arrays.

6. **Zero-dependency invariant** (ADR-0002): build.zig.zon has no external packages. ADR-0003 exception for system OpenSSL via @cImport. F010 respects this — stdlib-only OTLP exporter, manual JSON serialization.

7. **Background compression counter**: Spec defines `ztick.persistence.compactions` metric. F009 is fully implemented (commit 43e721e). Counter will track actual compression completions.

**Sources**: git log, docs/ADR/, .specify/implementation/F008/research.md, .specify/implementation/F009/research.md, src/interfaces/dump.zig:39-95
**Recommendation**: Follow established config/threading/atomic patterns. For HTTP client (new territory), implement defensively: bounded timeouts, non-blocking failure handling, connection reuse. JSON serialization follows dump.zig writer pattern — direct emission, no intermediate allocation.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: Minimal cleanup needed — F010 is a greenfield addition:

1. **No existing telemetry code**: No references to telemetry, metrics, observability, otel, opentelemetry, counter, gauge, or histogram in src/. Pure greenfield implementation.

2. **No dead code detected**: All underscore-prefixed assignments are legitimate test cleanup or deinit result ignoring. No unreferenced functions or suppressed imports (the F009 background.zig suppression was already resolved).

3. **No deprecated patterns**: No TODO/FIXME/HACK markers related to observability or monitoring.

4. **Potential consolidation opportunity**: The `Process` struct (infrastructure/persistence/background.zig:14-44) uses thread + mutex + result for async task tracking. The exporter thread will need a similar pattern. Consider whether to extract a reusable ThreadWorker utility or keep patterns separate (YAGNI — different lifecycle requirements may justify separate implementations).

5. **Logging extension (not replacement)**: Existing std.log infrastructure (8 log statements across src/) will be extended for OTLP log export at warn+ level. The custom logFn in main.zig (lines 27-61) remains as-is; OTLP log capture adds a parallel path.

**Sources**: Global grep across src/, src/infrastructure/persistence/background.zig:14-44, src/main.zig:27-61
**Recommendation**: No deletion needed. The Process consolidation is optional — evaluate during implementation whether the exporter thread's lifecycle requirements (periodic flush, bounded shutdown timeout, HTTP connection management) are sufficiently different from Process (one-shot task, poll for completion) to warrant a separate implementation. Likely yes — keep separate.

## Best Practices

| Pattern | Application in F010 |
|---------|----------------------------|
| Atomic counters (std.atomic.Value) | MetricRegistry uses atomic u64 for counters, atomic i64 for gauges — zero-lock metric updates from scheduler tick loop |
| Channel(T) bounded queue | Exporter thread receives Span and LogRecord batches via dedicated Channel, bounded buffer prevents unbounded memory growth |
| Config section parsing | Add [telemetry] section with known-key validation, ConfigError on unknown keys, defaults when section absent |
| Set-before-spawn | Initialize MetricRegistry and TelemetryConfig in main() before spawning exporter thread — no synchronization needed |
| Tagged union method dispatch | Optional telemetry: when disabled, all instrumentation calls are no-ops (null registry pattern or comptime branch) |
| Process.execute() background task | Exporter thread follows Process spawn pattern but with periodic loop instead of one-shot task |
| JSON writer pattern (dump.zig) | OTLP JSON serialization uses direct writer.writeAll/writeByte — no intermediate buffers or std.json |
| Shutdown: atomic flag + channel close + join | Exporter thread checks running flag, honors channel close, attempts final flush with bounded timeout |
| Clock periodic callback | Flush interval implementation — exporter loop sleeps for flush_interval_ms between export cycles |
| DatabaseContext config carrier | TelemetryContext struct passes parsed config from main.zig to exporter thread initialization |
| Verbose test naming | "telemetry exports counter when job scheduled", "disabled telemetry has zero overhead" |
| tmpDir for test isolation | Exporter tests use tmpDir or in-memory capture to verify serialized JSON without network I/O |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| std.http.Client | stdlib (Zig 0.14.0+) | HTTP POST for OTLP export to collector | available | none — first usage in codebase |
| std.atomic.Value | stdlib (Zig 0.14.0+) | Lock-free metric counter/gauge updates | installed | already used for active_connections, running flag |
| std.Thread | stdlib (Zig 0.14.0+) | Exporter thread spawning | installed | already used for controller/database/processor threads |
| std.time | stdlib (Zig 0.14.0+) | Nanosecond timestamps for spans and flush intervals | installed | already used in scheduler tick loop |
| std.io.Writer | stdlib (Zig 0.14.0+) | OTLP JSON serialization to HTTP body | installed | already used in dump.zig JSON writer |

No external dependencies required. Zero-dependency invariant (ADR-0002) maintained.

## References

| File | Relevance |
|------|-----------|
| src/application/scheduler.zig | Primary instrumentation target — tick loop, handle_query, compression triggers |
| src/infrastructure/tcp_server.zig | Connection gauge instrumentation, atomic counter pattern reference |
| src/infrastructure/channel.zig | Channel(T) for exporter thread communication |
| src/infrastructure/clock.zig | Periodic callback pattern for flush interval |
| src/infrastructure/persistence/background.zig | Process struct — background task lifecycle pattern |
| src/interfaces/config.zig | Config parsing extension point for [telemetry] section |
| src/interfaces/dump.zig | JSON writer pattern (manual writeAll, no std.json) |
| src/main.zig | Thread spawning, shutdown coordination, context struct wiring |
| src/domain/execution.zig | ExecutionRequest/Response — trace correlation via u128 identifiers |
| src/functional_tests.zig | Functional test patterns — helpers, process-based CLI tests |
| docs/ADR/0001-hexagonal-architecture.md | Layer placement decisions |
| docs/ADR/0002-zig-language-choice.md | Zero-dependency constraint |
| .specify/implementation/F009/research.md | Closest prior feature — background thread + scheduling patterns |
