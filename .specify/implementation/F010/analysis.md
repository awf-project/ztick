ARTIFACT_ANALYSIS

## Findings

| ID | Category | Severity | Location | Summary | Recommendation |
|----|----------|----------|----------|---------|----------------|
| F1 | Ordering | CRITICAL | tasks:T007, tasks:T002–T005 | T007 registers telemetry modules in build.zig but depends on T006 (Phase 3 end). T002–T005 all invoke `zig build test-application` / `test-infrastructure` in their acceptance criteria — those tests cannot compile until T007 runs. The dependency graph edge `T006 → T007` must be reversed; T007 should precede T002. | Move T007 to Phase 1 or make it a prerequisite of T002, with no dependency on T006. |
| F2 | Coverage | CRITICAL | spec:FR-002, tasks:— | `ztick.connections.active` gauge is required by FR-002, assigned to tcp_server.zig (T006 mentions passing the gauge to TCP server context), but no task instruments the connect/disconnect call sites in `src/infrastructure/tcp_server.zig`. T005 only covers scheduler instrumentation; T006 covers main.zig wiring. The actual increment/decrement in the TCP server layer has no owning task. | Add a task to instrument `tcp_server.zig` connect/disconnect paths for the `connections_active` gauge. |
| F3 | Terminology | HIGH | spec:FR-002 / plan:§T002 | Spec FR-002 declares `ztick.jobs.executed` as a single counter with a `success` label. T002 models this as two separate atomic counters (`jobs_executed_success`, `jobs_executed_failure`). In OTLP, these produce different metric names and schemas. A single counter with a `success` attribute is not equivalent to two separate counters. | Reconcile: either adopt labeled data points (one counter, emit two data points with `success=true/false`) or explicitly update FR-002 to reflect the two-counter design and align serialization in T003/T009 accordingly. |
| F4 | Terminology | HIGH | spec:§Key Entities / plan/tasks:— | `ExportBatch` is defined as a Key Entity in the spec with attributes `metrics, spans, log_records, record_count, byte_estimate`. It is never referenced in the plan or tasks. The plan instead describes "snapshots" and "Channel batching," which may or may not implement the same contract. | Either add `ExportBatch` to the implementation plan (T003/T004) or remove it from the spec's Key Entities and replace with the actual design (snapshot + channel). |
| F5 | Coverage | HIGH | spec:NFR-004, tasks:— | NFR-004 requires bounded buffer with drop-oldest behavior and a warning log when full. T004's acceptance only tests "unreachable endpoint without crashing" and "flush on shutdown." No task creates a test verifying the drop-oldest policy or the warning emission. | Add acceptance criterion to T004 (or a new test task) covering buffer-full drop and the resulting warn log. |
| F6 | Underspecification | HIGH | spec:FR-011, tasks:T003 | FR-011 requires `service.version` as a resource attribute on all exported signals. No task, file, or assumption identifies the source of the version string. The codebase has no versioning mechanism documented. | Add an assumption or task specifying how `service.version` is obtained (e.g., comptime constant in build.zig, hardcoded "0.1.0", or a build option). |
| F7 | Ambiguity | MEDIUM | spec:FR-010, tasks:T004 | "Bounded timeout" for flush-on-shutdown is specified in FR-010 but no value is given. T004's acceptance says "exporter flushes on shutdown signal" without a timeout value, making the criterion non-deterministic in tests. | Define a concrete default timeout (e.g., 2000ms) in TelemetryConfig or as a constant; reference it in T004's acceptance criterion. |
| F8 | Underspecification | MEDIUM | tasks:T016 | T016 acceptance requires a "mock HTTP endpoint" that receives OTLP JSON. In Zig stdlib, this requires a TCP listener speaking HTTP/1.1 — non-trivial and not covered by any existing test infrastructure task. No helper or test server design is specified. | Add a sub-task or note to T016 specifying the mock implementation approach (e.g., `std.net.StreamServer` in the test, or a helper in `tests/`). |
| F9 | Underspecification | MEDIUM | tasks:T015 | T015 acceptance criterion requires verifying "no additional threads spawned." Zig stdlib has no API to enumerate live threads. As stated, this acceptance criterion is untestable. | Replace with a testable proxy: verify no HTTP connections are attempted (e.g., no TCP connect to the telemetry endpoint address) and that the process exits within a tight timeout when telemetry is disabled. |
| F10 | Underspecification | MEDIUM | spec:§Edge Cases, tasks:T001 | Spec edge case: "malformed endpoint rejected at startup with clear error." T001 acceptance only covers `enabled=true` without endpoint. URL format validation is not listed as an acceptance criterion for T001. | Add acceptance criterion to T001: `parse rejects telemetry endpoint with invalid URL format`. |
| F11 | Ambiguity | MEDIUM | tasks:§Metrics header | Tasks document header states "Phases: 5" but the task list defines 7 named phases (Phase 1–7). | Correct the Metrics table to show 7 phases. |
| F12 | Terminology | LOW | plan:T006, plan:§Components | Plan Components section names the thread-wiring component `thread_wiring` and its thread `TelemetryContext`. T006 and T004 refer to it as `OtlpExporter`. Two names for the same struct across plan artifacts. | Standardize on one name (recommend `OtlpExporter` since it's more descriptive) throughout plan and tasks. |
| F13 | Ambiguity | LOW | spec:SC-001 | SC-001 success criterion: "within 2 flush intervals" is configurable (5000ms default → 10s, or custom). The criterion is meaningful only relative to a specific flush_interval_ms value. | Anchor SC-001 to the default: "within 10 seconds (2× default 5000ms flush interval)". |

---

## Coverage Map

| Requirement | Has Task? | Task IDs | Notes |
|-------------|-----------|----------|-------|
| FR-001 (export metrics via OTLP/HTTP) | Yes | T003, T004, T006 | |
| FR-002 (7 specific metrics) | Partial | T002, T005, T006 | `connections_active` increment in tcp_server has no owning task (F2) |
| FR-003 (export traces to /v1/traces) | Yes | T009, T011 | |
| FR-004 (trace context propagation across threads) | Yes | T010 | |
| FR-005 (export logs to /v1/logs) | Yes | T013, T014 | |
| FR-006 (parse [telemetry] config section) | Yes | T001 | |
| FR-007 (disabled by default) | Yes | T001 | |
| FR-008 (reject unknown keys) | Yes | T001 | |
| FR-009 (batch export with periodic flush) | Yes | T004 | |
| FR-010 (flush on shutdown, bounded timeout) | Partial | T004 | Timeout value unquantified (F7) |
| FR-011 (resource attributes on all signals) | Partial | T003 | service.version source unspecified (F6) |
| FR-012 (fixed histogram buckets) | Yes | T002 | |
| NFR-001 (zero overhead when disabled) | Partial | T015 | Test acceptance criterion untestable as written (F9) |
| NFR-002 (metric updates non-blocking) | Partial | T005, T006 | No performance test; architectural compliance only |
| NFR-003 (export failure non-crashing) | Yes | T004 | |
| NFR-004 (bounded buffer, drop oldest) | Partial | T004 | Drop-oldest behavior and warn log have no test (F5) |
| NFR-005 (stdlib only) | Yes | T007 | |
| NFR-006 (exporter respects shutdown pattern) | Yes | T006 | |

---

## Metrics

- Total Requirements: 18 (12 FR + 6 NFR)
- Total Tasks: 18
- Coverage: 83% (15 requirements with full task coverage; 3 partial with documented gaps)
- Critical Issues: 2
- High Issues: 4
- Ambiguities: 3
- Gaps: 4

## Verdict

CRITICAL_COUNT: 2
HIGH_COUNT: 4
COVERAGE_PERCENT: 83
RECOMMENDATION: REVIEW_NEEDED
