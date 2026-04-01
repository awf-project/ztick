# Implementation Plan: F009

## Summary

Wire the existing `background.compress()` and `Process` executor into the scheduler's tick loop with a time-based trigger policy. Add `compression_interval` config key, conditional `.logfile`-only guard, and file rotation (atomic rename) before compression. No new algorithms or threading primitives -- purely scheduling logic and integration wiring.

## Constitution Compliance

| Principle | Status | Notes |
|-----------|--------|-------|
| P1: Hexagonal Architecture | COMPLIANT | Timer logic in application/scheduler.zig, file I/O stays in infrastructure/persistence/background.zig, config parsing in interfaces/config.zig, wiring in main.zig |
| P2: TDD Methodology | COMPLIANT | Unit tests co-located in each modified file; functional tests in functional_tests.zig; all components independently testable |
| P3: Zig Idioms | COMPLIANT | Error unions for fallible operations, explicit allocator passing, std.log for warnings, no hidden allocations |
| P4: Minimal Abstraction | COMPLIANT | No new types -- compression state added as fields on Scheduler struct; reuses existing Process executor and compress() function |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.14.0+ |
| Framework | None (stdlib only, ADR-0002) |
| Architecture | Hexagonal (4-layer: domain, application, infrastructure, interfaces) |
| Key patterns | Tagged union dispatch (PersistenceBackend), variant-gated background work (Pattern-56), atomic rename for persistence, three-thread concurrency model, Clock-driven tick loop |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | Where should compression scheduling state live -- new struct or fields on Scheduler? | Add fields directly to Scheduler struct (3 fields: interval_ns, last_compression_ns, active_process). No separate type needed -- Scheduler already owns persistence and tick() receives timestamps. | `src/application/scheduler.zig:16-21` -- Scheduler struct already holds `persistence: ?PersistenceBackend`; adding 3 more fields follows the same pattern. Constitution P4 says "No interface without 2+ implementations." |
| A2 | How does the tick loop get nanosecond timestamps for interval checking? | `tick(current_time: i64)` already receives nanoseconds from `std.time.nanoTimestamp()` at `main.zig:187`. Use `current_time` directly. | `src/main.zig:187` -- `const now: i64 = @intCast(std.time.nanoTimestamp()); self.scheduler.tick(now)` |
| A3 | How to pass compression config from main.zig to the scheduler? | Add `compression_interval_ns` field to `DatabaseContext` struct, then set it on Scheduler before entering the tick loop, following F008's pattern for persistence config. | `src/main.zig:120-129` -- DatabaseContext already carries `framerate` and `persistence` fields set in main(). |
| A4 | Does LogfilePersistence.append() auto-create a new logfile after rename? | Yes. `append()` uses `openFile(.write_only) catch FileNotFound => createFile`, so after the active logfile is renamed away, the next append transparently creates a fresh file. | `src/infrastructure/persistence/backend.zig:19-21` -- fallback to `createFile` on `FileNotFound` |
| A5 | How to get `logfile_dir` and `logfile_path` from Scheduler for compression? | Access via `self.persistence.?.logfile.logfile_dir` and `.logfile_path`. The PersistenceBackend tagged union exposes `.logfile` variant fields. | `src/infrastructure/persistence/backend.zig:6-10` -- LogfilePersistence has `logfile_dir: ?std.fs.Dir` and `logfile_path: ?[]const u8` |
| A6 | Should `compression_interval` default type be u32 or u64? | u32 -- max value 4,294,967,295 seconds (~136 years), more than sufficient. Follows framerate pattern of bounded integer types. | `src/interfaces/config.zig:109-111` -- framerate parsed as u16 with range validation |

## Approach Comparison

| Criteria | Approach A: Inline in Scheduler | Approach B: Separate CompressionScheduler struct | Approach C: Compression in Clock callback |
|----------|--------------------------------|--------------------------------------------------|-------------------------------------------|
| Description | Add 3 fields to Scheduler, check interval in tick(), call compress via Process | Create new CompressionScheduler struct with its own init/tick/deinit, composed into Scheduler | Add a second Clock loop dedicated to compression |
| Files touched | 4 (config, scheduler, main, functional_tests) | 5 (config, scheduler, main, new file, functional_tests) | 5 (config, main, new file, clock, functional_tests) |
| New abstractions | 0 | 1 (CompressionScheduler) | 1 (compression callback) + thread |
| Risk level | Low | Med | High |
| Reversibility | Easy | Easy | Hard (new thread model) |

**Selected: Approach A**
**Rationale:** Scheduler already owns persistence, receives timestamps via tick(), and manages the database thread lifecycle. Three fields (interval_ns, last_compression_ns, active_process) is minimal. Constitution P4 prohibits unnecessary abstractions. The tick loop naturally provides the polling point for both interval checking and process status.
**Trade-off accepted:** If compression scheduling grows complex (mutation-count triggers, multiple policies), the fields would need extraction. The spec explicitly defers this to future work.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| Store interval as nanoseconds (i128 or i64) internally | Tick loop uses i64 nanoseconds; direct comparison avoids conversion on every tick. Multiply config seconds * ns_per_s at construction time. | Storing as seconds and converting per-tick -- unnecessary overhead at 512 Hz |
| Use `?*Process` for active_process field | Null when no compression running; non-null when active. Process is heap-allocated by `Process.execute()`. Clean nullable semantics. | Bool flag + separate process handle -- two fields for one concept |
| File rotation (rename + fresh file) happens in tick(), not in background thread | Rename must complete before compression starts; it must happen atomically relative to append(). The tick loop is single-threaded (database thread), making this safe without locks. | Delegating rename to the background thread -- would require a coordinator lock between append and rename |
| Skip compression when `active_process != null` and status is `.running` | FR-004 requires skipping overlapping cycles. Polling `Process.status()` is mutex-protected and non-blocking. | Timer reset approach -- would silently extend intervals |
| Do not join() Process thread on shutdown | FR-005: shutdown must not block. Process.deinit() only frees the heap allocation. The background thread is fire-and-forget. Append-only logfile design ensures no corruption. | Joining with timeout -- adds complexity, the thread will terminate naturally |
| Compression interval 0 = disabled | FR-007 spec requirement. Checked once at construction; avoids per-tick branch for disabled compression. | Separate boolean flag -- adds config surface per spec's deferred decision |

## Components

```json
[
  {
    "name": "parse_compression_interval",
    "project": "",
    "layer": "interfaces",
    "description": "Add database_compression_interval field to Config struct and parse it from [database] section with default 3600, validation (u32), and 0-means-disabled semantics",
    "files": ["src/interfaces/config.zig"],
    "tests": ["src/interfaces/config.zig"],
    "dependencies": [],
    "user_story": "US4",
    "verification": {
      "test_command": "zig build test-interfaces --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "schedule_compression_in_tick",
    "project": "",
    "layer": "application",
    "description": "Add compression scheduling fields to Scheduler (interval_ns, last_compression_ns, active_process). In tick(), check elapsed time, guard on .logfile backend, perform file rotation (rename active logfile to .to_compress, Process.status() polling, spawn compression via Process.execute()), and cleanup completed processes",
    "files": ["src/application/scheduler.zig"],
    "tests": ["src/application/scheduler.zig"],
    "dependencies": ["parse_compression_interval"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-application --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "wire_compression_into_runtime",
    "project": "",
    "layer": "interfaces",
    "description": "Add compression_interval_ns to DatabaseContext, pass parsed config to Scheduler in run_database(), replace import suppression '_ = infrastructure_persistence_background' with actual usage. Handle leftover .to_compress file at startup (FR-009)",
    "files": ["src/main.zig"],
    "tests": ["src/main.zig"],
    "dependencies": ["parse_compression_interval", "schedule_compression_in_tick"],
    "user_story": "US1, US2",
    "verification": {
      "test_command": "zig build test-all --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "functional_test_compression_cycle",
    "project": "",
    "layer": "infrastructure",
    "description": "End-to-end functional tests: (1) scheduler with logfile backend triggers compression after interval and produces deduplicated .compressed file, (2) memory backend with compression_interval produces no file artifacts, (3) shutdown during compression exits promptly",
    "files": ["src/functional_tests.zig"],
    "tests": ["src/functional_tests.zig"],
    "dependencies": ["wire_compression_into_runtime"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-functional --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  }
]
```

## Test Plan

### Unit Tests

**config.zig** (co-located):
- `test "parse defaults compression_interval to 3600 when key absent"` -- FR-006
- `test "parse sets compression_interval from config value"` -- FR-010
- `test "parse sets compression_interval to zero for disabled compression"` -- FR-007
- `test "parse rejects negative or overflow compression_interval"` -- Edge case (u32 overflow)

**scheduler.zig** (co-located):
- `test "tick triggers compression after interval elapses for logfile backend"` -- FR-001, US1
- `test "tick skips compression when backend is memory"` -- FR-002, US2, NFR-003
- `test "tick skips compression when previous process is still running"` -- FR-004
- `test "tick cleans up completed compression process"` -- NFR-004
- `test "tick skips compression when interval is zero"` -- FR-007
- `test "tick renames logfile to .to_compress before spawning compression"` -- FR-003
- `test "tick logs warning when compression fails"` -- FR-008

**main.zig** (co-located):
- `test "DatabaseContext holds compression interval"` -- wiring verification

### Functional Tests

**functional_tests.zig**:
- `test "compression produces deduplicated logfile after interval"` -- SC-001, US1 independent test
- `test "memory backend produces no compression artifacts"` -- SC-004, US2 independent test
- `test "leftover .to_compress file is compressed at startup"` -- FR-009

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| File rotation race: append() called between rename and fresh file creation | Low | P1 | Tick loop is single-threaded (database thread); append() and tick() run sequentially in the same Clock callback. No concurrent writers. | Developer |
| Compression thread outlives process on shutdown, causing resource leak | Med | P2 | Process is heap-allocated, thread is detached on deinit. OS reclaims on process exit. Append-only design ensures no data corruption. Log warning if active_process exists at shutdown. | Developer |
| Existing 237+ tests break due to Scheduler struct field additions | Low | P0 | New fields have defaults (interval_ns=0, last_compression_ns=0, active_process=null). Scheduler.init() sets them. Existing tests that don't set compression fields get disabled compression (interval 0). | Developer |
| Interval drift due to nanosecond timestamp wrapping | Low | P2 | i64 nanoseconds overflow at ~292 years. Not a practical concern. Document assumption. | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| `src/main.zig:92` -- `_ = infrastructure_persistence_background` | Import suppression becomes unused when background module is actually wired | Replace suppression with actual usage in test block |
| `src/main.zig:22` -- `infrastructure_persistence_background` import | Currently only used for test reference; will gain production usage | Keep import, remove `_ =` suppression on line 92 |
