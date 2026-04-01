# Implementation Plan: F012

## Summary

Add a `STAT` protocol command that returns 15 key-value server health metrics (uptime, job/rule counts, execution pipeline state, persistence/compression status, and configuration indicators). The implementation follows the established LISTRULES pattern — a no-argument, read-only command with multi-line response — but handles metric collection directly in `Scheduler.handle_query()` rather than `QueryHandler`, since STAT aggregates data from multiple scheduler-owned subsystems.

## Constitution Compliance

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal Architecture | COMPLIANT | `ServerStats` lives in domain layer (zero deps); metric collection in application layer (Scheduler); protocol parsing in infrastructure layer; wiring in interfaces (src/main.zig) |
| TDD Methodology | COMPLIANT | Unit tests for `ServerStats.format()`, `Scheduler.handle_query` with `.stat`, parser; functional test for end-to-end STAT over scheduler |
| Zig Idioms | COMPLIANT | Error unions propagated with `try`; explicit allocator for body construction; `ArrayListUnmanaged` writer pattern; no hidden allocations |
| Minimal Abstraction | COMPLIANT | No new interfaces or abstractions; `ServerStats` is a plain value struct with a `format()` method; follows existing patterns exactly |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.15.2 |
| Framework | stdlib-only (+ zig-o11y for telemetry, system OpenSSL for TLS) |
| Architecture | Hexagonal: domain → application → infrastructure → interfaces |
| Key patterns | Tagged unions for commands, `ArrayListUnmanaged(u8)` writer for multi-line response bodies, `struct {}` payload for no-argument commands, exhaustive switch enforcement, `GeneralPurposeAllocator` with leak detection in tests |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | Where to handle STAT: QueryHandler or Scheduler? | Scheduler intercepts `.stat` before delegating to QueryHandler, since STAT needs `execution_client`, `active_process`, `active_connections`, and `persistence` — all owned by Scheduler, not QueryHandler | `scheduler.zig:18-28` — Scheduler owns all required subsystems; `query_handler.zig:12-23` — QueryHandler only has `job_storage` and `rule_storage` |
| A2 | How does STAT get `active_connections` from the TCP server thread? | Pass `*std.atomic.Value(usize)` pointer from TcpServer to Scheduler via new field; cross-thread atomic read with `.acquire` ordering | `tcp_server.zig:85` — `active_connections` is already `std.atomic.Value(usize)`; `tcp_server.zig:132,158` — already read cross-thread in `join_all()` |
| A3 | How to represent compression status when `active_process` is null? | Map `null` → `"idle"` (simplest). The spec says "null → idle", not distinguishing between "never started" and "completed" | `scheduler.zig:191-203` — `active_process` set to `null` after both success and failure; spec lines 124,224 confirm idle/running/success/failure mapping |
| A4 | Should `uptime_ns` use `i128` (nanoTimestamp return type) or `i64`? | Use `i128` to match `std.time.nanoTimestamp()` return type, format as decimal integer in response | `std.time.nanoTimestamp` returns `i128`; spec says "i64" but i128 avoids truncation and serves 292+ years |
| A5 | How does write_response know to use multi-line format for STAT? | Add `.stat` to the existing `.query, .list_rules` match arm in `write_response()` | `tcp_server.zig:467-468` — multi-line output is already a switch arm matching `.query, .list_rules` |
| A6 | F011 (auth) not merged — how to report `auth_enabled`? | Pass `auth_enabled: bool` from config/src/main.zig to Scheduler; defaults to `false` on current main branch; will automatically report `1` once F011 is wired | `config.zig:32-53` — no `auth_file` field yet; spec FR-003 requires `auth_enabled` metric |

## Approach Comparison

| Criteria | Approach A: Scheduler-direct | Approach B: Extend QueryHandler | Approach C: New StatHandler |
|----------|-------------------|-------------------|-------------------|
| Description | Intercept `.stat` in `Scheduler.handle_query()` before QueryHandler dispatch | Add scheduler context fields to QueryHandler, handle `.stat` in its switch | Create dedicated `StatHandler` struct parallel to `QueryHandler` |
| Files touched | 7 | 7 | 8 (new file) |
| New abstractions | 1 (ServerStats) | 1 (ServerStats) | 2 (StatHandler + ServerStats) |
| Risk level | Low | Med (pollutes QueryHandler with unrelated context) | Med (new module for single use) |
| Reversibility | Easy | Easy | Easy |

**Selected: Approach A**
**Rationale:** Scheduler already owns all data sources STAT needs. Intercepting before QueryHandler keeps QueryHandler focused on CRUD (matching its current design at `query_handler.zig:25-92`). The tasks.md plan also selects this approach. No new modules beyond the `ServerStats` domain type.
**Trade-off accepted:** STAT handling lives in Scheduler rather than being colocated with other read-only commands in QueryHandler, creating a minor inconsistency. This is acceptable because the data access pattern is fundamentally different.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| `ServerStats` as domain struct with `format()` method | Keeps response formatting logic testable in isolation; domain layer owns the value object definition | Inline formatting in Scheduler (harder to unit test format correctness) |
| Intercept `.stat` in `handle_query()` before `QueryHandler.handle()` | Avoids passing 5+ extra context fields to QueryHandler that only STAT uses | Extending QueryHandler with operational context |
| Pass `active_connections` pointer and config booleans as Scheduler fields | Minimal change to Scheduler struct; pointer avoids copying atomic state | Passing via handle_query parameter (would change signature for all callers) |
| `uptime_ns` stored as `i128` | Matches `std.time.nanoTimestamp()` return type exactly; avoids truncation | `i64` (spec says i64, but nanoTimestamp returns i128) |

## Components

```json
[
  {
    "name": "stat_domain_types",
    "project": "",
    "layer": "domain",
    "description": "Add stat variant to Instruction union and ServerStats value struct with format() method",
    "files": [
      "src/domain/instruction.zig",
      "src/domain/server_stats.zig",
      "src/domain.zig"
    ],
    "tests": [
      "src/domain/instruction.zig",
      "src/domain/server_stats.zig"
    ],
    "dependencies": [],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-domain",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "stat_scheduler_handling",
    "project": "",
    "layer": "application",
    "description": "Add stat context fields to Scheduler, intercept .stat in handle_query(), skip persistence and update telemetry switch",
    "files": [
      "src/application/scheduler.zig"
    ],
    "tests": [
      "src/application/scheduler.zig"
    ],
    "dependencies": ["stat_domain_types"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-application",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "stat_protocol_parsing",
    "project": "",
    "layer": "infrastructure",
    "description": "Parse STAT command in build_instruction(), add .stat to free_instruction_strings() and write_response() multi-line arm, skip namespace auth for STAT",
    "files": [
      "src/infrastructure/tcp_server.zig"
    ],
    "tests": [
      "src/infrastructure/tcp_server.zig"
    ],
    "dependencies": ["stat_domain_types"],
    "user_story": "US1, US4",
    "verification": {
      "test_command": "zig build test-infrastructure",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "stat_main_wiring",
    "project": "",
    "layer": "interfaces",
    "description": "Capture startup_ns at boot, pass active_connections pointer and config flags (auth_enabled, tls_enabled, framerate) to Scheduler",
    "files": [
      "src/main.zig"
    ],
    "tests": [],
    "dependencies": ["stat_scheduler_handling"],
    "user_story": "US1",
    "verification": {
      "test_command": "make build",
      "expected_output": "exit 0",
      "build_command": "make build"
    }
  },
  {
    "name": "stat_functional_tests",
    "project": "",
    "layer": "application",
    "description": "Functional tests: STAT returns all 15 metrics via scheduler, no persistence entry, correct format",
    "files": [
      "src/functional_tests.zig"
    ],
    "tests": [
      "src/functional_tests.zig"
    ],
    "dependencies": ["stat_scheduler_handling", "stat_protocol_parsing", "stat_main_wiring"],
    "user_story": "US1, US2, US3, US4",
    "verification": {
      "test_command": "zig build test-functional",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "stat_documentation",
    "project": "",
    "layer": "interfaces",
    "description": "Update protocol reference and README with STAT command docs",
    "files": [
      "docs/reference/protocol.md",
      "README.md"
    ],
    "tests": [],
    "dependencies": ["stat_functional_tests"],
    "user_story": "US1",
    "verification": {
      "test_command": "make test",
      "expected_output": "All tests passed",
      "build_command": "make build"
    }
  }
]
```

## Test Plan

### unit_tests

**ServerStats.format()** (`src/domain/server_stats.zig`):
- Verify format output contains all 15 `key value\n` lines in logical order
- Verify boolean fields render as `0`/`1`
- Verify string fields (persistence, compression) render correctly

**Scheduler.handle_query with .stat** (`src/application/scheduler.zig`):
- Verify `.stat` returns success response with body containing expected metric keys
- Verify job count metrics match pre-populated storage state (planned, triggered, executed, failed)
- Verify no persistence entry created for `.stat`

**Instruction.stat active tag** (`src/domain/instruction.zig`):
- Verify `stat` variant is active tag (follows existing pattern at line 78-81)

**build_instruction parses STAT** (`src/infrastructure/tcp_server.zig`):
- Verify `STAT` input produces `Instruction{ .stat = .{} }`
- Verify `STAT` with extra arguments still produces `.stat` (silently ignored)

### functional_tests

**STAT returns metrics via scheduler** (`src/functional_tests.zig`):
- Send `.stat` request through scheduler; verify response body contains `uptime_ns`, `connections`, `jobs_total`, all 15 metric keys
- Verify terminal response format (success=true, body contains newline-separated key-value pairs)

**STAT does not persist** (`src/functional_tests.zig`):
- Execute STAT on scheduler with logfile persistence; verify no entries appended

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Changing `Scheduler.init()` signature breaks all existing tests | High | P1 | Add new fields with defaults or use a separate `setStatContext()` method after init (like `setInstruments` at `scheduler.zig:43-45`) | Developer |
| `active_connections` pointer lifetime: TcpServer and Scheduler on different threads | Low | P1 | `active_connections` lives in TcpServer on stack of `run_controller`; scheduler reads via atomic. Both threads joined before main exits. Pointer valid for duration. | Developer |
| F011 not merged — `auth_enabled` field and namespace bypass logic may conflict when F011 merges | Med | P0 | Wire `auth_enabled` as `bool` field defaulting to `false`; add TODO-free code path that simply reports the boolean. F011 merge will need to set this field from auth config. Zig exhaustive switch will catch any missing `.stat` arms. | Developer |
| `get_by_status()` iterates all jobs 4 times for status counts — performance concern at scale | Low | P2 | All data is in-memory HashMap iteration; 15 metrics are cheap reads. For v1, this is acceptable. Future optimization: maintain counters incrementally. | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| None | STAT introduces new capability without replacing anything | No cleanup needed |

Notes: The response formatting duplication between QUERY/LISTRULES/STAT (identified in research Q5) is explicitly out of scope per CLAUDE.md guidelines on premature abstraction.
