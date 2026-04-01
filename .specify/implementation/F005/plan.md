# Implementation Plan: F005

## Summary

Wire the existing but unused `Config.log_level` to Zig's `std.log` via a custom `logFn` in `main.zig`, add structured log output at startup and runtime events (connections, instructions, execution), and replace existing silent error catches with proper log calls.

## Constitution Compliance

Constitution: Derived from CLAUDE.md

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal layering | COMPLIANT | Logging is a cross-cutting concern wired at interfaces layer (main.zig); infrastructure files (tcp_server.zig) use std.log directly — no new cross-layer imports needed |
| Tagged unions with `struct {}` payloads | COMPLIANT | No new tagged union variants introduced |
| Error unions for fallible operations | COMPLIANT | logFn is infallible (std.log contract); no new error types needed |
| Barrel exports only | COMPLIANT | No new barrel imports; std.log is globally accessible via Zig's root module |
| Co-located unit tests | COMPLIANT | Tests for logLevelToStd mapping and logFn added in main.zig |
| Verbose test names describing behavior | COMPLIANT | Test names describe observable behavior from caller perspective |
| snake_case naming | COMPLIANT | All new functions follow convention |
| No global allocators | COMPLIANT | logFn uses stack-based formatting via std.io.getStdErr().writer() |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.14.0+ |
| Framework | stdlib only (std.log, std.io) |
| Architecture | Hexagonal 4-layer (domain, application, infrastructure, interfaces) |
| Key patterns | set-before-spawn for runtime log level, custom std_options logFn, `@tagName` for instruction type logging |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | How to map `Config.LogLevel` (6 variants) to `std.log.Level` (4 variants: err, warn, info, debug) | `off` → suppress all output in logFn; `trace` → map to `std.log.Level.debug` (most permissive); `error` → `.err`; others map by name | `config.zig:3-10` defines 6 levels; `std.log.Level` has `.err, .warn, .info, .debug` |
| A2 | Whether runtime log level variable needs synchronization | No — set once in main() before any thread is spawned (set-before-spawn pattern); threads only read | `main.zig:266-293` shows thread spawning happens after config load at line 249 |
| A3 | Whether `std_options.log_level` comptime setting blocks runtime filtering | Set comptime level to `.debug` (most permissive) to pass all messages to logFn; logFn then applies runtime filter | Zig std.log filters at comptime first, then calls logFn — both gates must pass |
| A4 | Where to log connection address in tcp_server.zig | In `handle_connection` function which receives `stream` — but stream doesn't expose peer address directly; use `client_id` only | `tcp_server.zig:128-134` — `std.net.Stream` has `.handle` (fd) but not direct address; `connection_worker` at line 116 receives no address |
| A5 | How to access job/rule counts after `scheduler.load()` | `scheduler.job_storage.jobs.count()` and `scheduler.rule_storage.rules.count()` are accessible — but scheduler is created inside `run_database`, not in main() | `main.zig:96-100` — scheduler created in run_database thread; counts must be logged there, not in main() |
| A6 | Whether execution outcome logging belongs in scheduler.zig or execution_client.zig | In `scheduler.zig` tick() where `pull_results` is consumed and status transitions happen — this is where success/failure is known | `scheduler.zig:141-149` — tick() calls pull_results and updates job status |

## Approach Comparison

| Criteria | Approach A: std_options custom logFn | Approach B: Custom logger module | Approach C: Direct stderr writes |
|----------|--------------------------------------|----------------------------------|----------------------------------|
| Description | Define `pub const std_options` in main.zig with custom logFn; use `std.log.info/debug/err` throughout | Create interfaces/logger.zig module with writer abstraction, pass to thread contexts | Use `std.io.getStdErr().writer()` directly everywhere |
| Files touched | 4 (main.zig, tcp_server.zig, scheduler.zig, getting-started.md) | 6 (new logger.zig + main.zig + thread contexts + tcp_server.zig + scheduler.zig + docs) | 4 (main.zig, tcp_server.zig, scheduler.zig, docs) |
| New abstractions | 0 (uses stdlib std.log) | 1 (Logger module + Writer interface) | 0 |
| Risk level | Low | Med | Low |
| Reversibility | Easy | Hard (wired into contexts) | Easy |

**Selected: Approach A**
**Rationale:** Zig's `std.log` is designed for exactly this use case. The custom logFn is globally accessible without modifying thread context structs, aligning with the existing architecture where threads don't carry log configuration. The set-before-spawn pattern avoids synchronization. Zero new abstractions.
**Trade-off accepted:** Unit-testing logFn output requires a test-specific writer; Approach B would be more testable via dependency injection, but adds unnecessary abstraction for 3 threads.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| Set comptime `std_options.log_level = .debug` | Must be most permissive to allow runtime filtering in logFn; if set to .info, debug/trace messages are stripped at comptime | Per-level comptime gates (would prevent runtime control) |
| Log database state (job/rule counts) inside `run_database` not `main()` | Scheduler is created and loaded in `run_database` thread; cannot access counts from main | Exposing counts via shared state or return channel (over-engineering) |
| Use `@tagName(instruction)` for DEBUG instruction logging | Automatically gives human-readable variant name without maintaining a separate string map | Manual switch statement mapping instruction to string (maintenance burden) |
| Replace `std.debug.print` at main.zig:89 with `std.log.err` | Consistent with new logging system; respects log level | Keep both (inconsistent output mechanisms) |
| Log format `[LEVEL] message\n` via logFn | Matches spec NFR-003; simple, parseable | Include timestamps (deferred per spec — no structured logging) |

## Components

```json
[
  {
    "name": "wire_std_log",
    "project": "",
    "layer": "interfaces",
    "description": "Define pub const std_options in main.zig with custom logFn that reads runtime_log_level variable; implement log_level_to_std mapping function from Config.LogLevel to std.log.Level",
    "files": ["src/main.zig"],
    "tests": ["src/main.zig"],
    "dependencies": [],
    "user_story": "US2",
    "verification": {
      "test_command": "zig build test-interfaces -- --test-filter \"log\"",
      "expected_output": "passed",
      "build_command": "make build"
    }
  },
  {
    "name": "startup_log_messages",
    "project": "",
    "layer": "interfaces",
    "description": "Add std.log.info calls in main() for config path and log level, listening address; add std.log.info in run_database after scheduler.load() for job/rule counts; replace std.debug.print at line 89 with std.log.err; add std.log.warn for scheduler.load() catch at line 100",
    "files": ["src/main.zig"],
    "tests": ["src/main.zig"],
    "dependencies": ["wire_std_log"],
    "user_story": "US1",
    "verification": {
      "test_command": "make test",
      "expected_output": "passed",
      "build_command": "make build"
    }
  },
  {
    "name": "connection_lifecycle_logging",
    "project": "",
    "layer": "infrastructure",
    "description": "Add std.log.info in handle_connection for client connect (on entry) and disconnect (on exit/stream close); add std.log.warn for silent catch blocks in ResponseRouter.route and write_response",
    "files": ["src/infrastructure/tcp_server.zig"],
    "tests": ["src/infrastructure/tcp_server.zig"],
    "dependencies": ["wire_std_log"],
    "user_story": "US3",
    "verification": {
      "test_command": "zig build test-infrastructure -- --test-filter \"tcp\"",
      "expected_output": "passed",
      "build_command": "make build"
    }
  },
  {
    "name": "instruction_execution_logging",
    "project": "",
    "layer": "infrastructure",
    "description": "Add std.log.debug in handle_connection when instruction is built (log instruction type via @tagName); add std.log.debug in scheduler.zig tick() when execution result is processed (job identifier + success/failure); add std.log.warn for silent catch in execution_client.zig resolve()",
    "files": ["src/infrastructure/tcp_server.zig", "src/application/scheduler.zig", "src/application/execution_client.zig"],
    "tests": ["src/infrastructure/tcp_server.zig", "src/application/scheduler.zig"],
    "dependencies": ["wire_std_log"],
    "user_story": "US4",
    "verification": {
      "test_command": "make test",
      "expected_output": "passed",
      "build_command": "make build"
    }
  },
  {
    "name": "update_documentation",
    "project": "",
    "layer": "interfaces",
    "description": "Update getting-started.md to replace 'no output expected' with realistic log output examples; update Step 7 restart section to show log output on reload; ensure configuration.md log level description matches actual behavior",
    "files": ["docs/tutorials/getting-started.md", "docs/reference/configuration.md"],
    "tests": [],
    "dependencies": ["startup_log_messages", "connection_lifecycle_logging"],
    "user_story": "US1",
    "verification": {
      "test_command": "make build",
      "expected_output": "Build Summary",
      "build_command": "make build"
    }
  }
]
```

## Test Plan

### Unit Tests (co-located in source files)

**wire_std_log (main.zig):**
- `test "log_level_to_std maps info to std.log.Level.info"` — verify each LogLevel variant maps correctly
- `test "log_level_to_std maps error to std.log.Level.err"` — verify the name mismatch (error→err) is handled
- `test "log_level_to_std maps trace to std.log.Level.debug"` — verify trace falls through to most permissive
- `test "logFn suppresses messages below runtime log level"` — use buffer writer to verify filtering
- `test "logFn formats output as bracket-level message newline"` — verify `[INFO] message\n` format

**No new tests needed for:**
- startup_log_messages — log calls are side-effects in main/run_database; verified manually and via functional test
- connection_lifecycle_logging — log calls in handle_connection are side-effects; existing tests verify no regression
- instruction_execution_logging — log calls in tick/handle_connection are side-effects; existing tests verify no regression

### Functional Tests

- Verify via `make test` that all 181+ existing test blocks still pass (logging adds no allocation, no new error paths)
- Manual verification: run `zig build run -- -c config.toml` and observe stderr output

### Coverage Targets

- 100% of `log_level_to_std` mapping branches (6 LogLevel variants)
- 100% of logFn format output (level bracket format)
- Existing test suite passes without regression

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Zig 0.14 std_options API differs from documented pattern | Low | P0 | Research confirmed `std.Options` struct exists in 0.14; verify with `make build` immediately after T1 | Implementer |
| logFn called from multiple threads causes interleaved output | Med | P2 | `std.io.getStdErr().writer()` is backed by POSIX write() which is atomic for small buffers; single-line format keeps messages under pipe buffer size | Implementer |
| Adding std.log calls to hot path (tick loop) impacts performance | Low | P1 | NFR-001 requires short-circuit: logFn checks runtime level before formatting; DEBUG logs only in tick result processing, not per-tick | Implementer |
| Test suite sensitive to stderr output (captures or asserts on it) | Low | P1 | Audited functional_tests.zig and main.zig tests: none capture stderr; all assertions use response channels or storage state | Implementer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| `main.zig:89` `std.debug.print("CONTROLLER: start failed...")` | Replaced by `std.log.err` | Delete |
| `main.zig:100` `catch {}` on scheduler.load | Replaced by `catch \|err\| { std.log.warn(...) }` | Replace |
| `getting-started.md:63` "No output is expected on startup" | Contradicted by new logging behavior | Replace with log output example |
| `execution_client.zig:48` `catch {}` on resolved.append | Silent OOM → `catch \|err\| std.log.err(...)` | Replace |
