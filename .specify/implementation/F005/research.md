# Research: F005 — Add Startup Logging

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig |
| Domain | CLI (time-based job scheduler) |
| Task Type | feature |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: Claude-mem observation #17032 confirms that the logging infrastructure gap was previously investigated. Config has `LogLevel` enum (off, error, warn, info, debug, trace) with `log_level` field parsed from TOML `[log]` section, defaulting to `.info`. However, `log_level` is **never wired** to any logging system — `main()` spawns three threads silently with zero output. The only output statement is a single `std.debug.print` at `main.zig:89` for controller startup errors. Documentation (`getting-started.md:63`) explicitly states "No output is expected on startup." Feature roadmap shows F001-F004 all IMPLEMENTED; F005 is the next feature. Implementation patterns memory documents 29 patterns from prior features, including exhaustive switch cascade (pattern #13), read-only command pattern (#20), and empty struct variant (#26).

**Sources**: claude-mem #17032, memory/feature_roadmap.md, memory/implementation_patterns.md, memory/test_conventions.md

**Recommendation**: Leverage existing LogLevel enum and Config infrastructure. Follow the domain → application → infrastructure → interfaces layering pattern established by F001-F004. Use `std_options` with custom `logFn` to wire runtime log level.

---

### Q1: [ARCH] What patterns should F005 follow?

**Finding**: The project uses strict 4-layer hexagonal architecture with barrel exports. Entry point is `src/main.zig` which:
- Parses CLI args via `interfaces_cli.Args.parse()` (line ~248)
- Loads config via `interfaces_config.load()` (line 249)
- Extracts config fields into 3 thread context structs (lines 58-83): `ControllerContext`, `DatabaseContext`, `ProcessorContext`
- Spawns 3 threads: `run_controller()` (TCP), `run_database()` (scheduler tick), `run_processor()` (shell executor) (lines 268-293)

**Critical gap**: `cfg.log_level` is loaded but never passed to any thread context struct and never used. No `std_options` or `std.log` usage exists in the codebase. The only output is `std.debug.print` at `main.zig:89`.

F005 is unique among features because it primarily touches `main.zig` (interfaces layer) rather than following the typical domain → application → infrastructure cascade. The logging system itself is a cross-cutting concern wired at the interfaces layer.

**Sources**: `src/main.zig:242-304`, `src/interfaces/config.zig:3-32`, `src/main.zig:58-83`

**Recommendation**:
1. Define `pub const std_options` in `main.zig` with a custom `logFn` that checks a module-level `var runtime_log_level` variable
2. Set `runtime_log_level` from `cfg.log_level` in `main()` before thread spawning (set-before-spawn pattern — no synchronization needed)
3. Add `std.log.info(...)` calls at startup milestones and `std.log.debug(...)` at runtime events
4. No need to pass log_level to thread contexts — `std.log` is globally accessible and the level variable is set before threads spawn

---

### Q2: [TYPES] Which types can F005 reuse?

**Finding**: Key types for F005:

| Type | Location | Relevance |
|------|----------|-----------|
| `LogLevel` enum | `config.zig:3-10` | Maps to `std.log.Level`; variants: off, error, warn, info, debug, trace |
| `Config` struct | `config.zig:20-32` | Contains `log_level`, `controller_listen`, `database_logfile_path` for startup log messages |
| `Scheduler` | `scheduler.zig:15-170` | Access `job_storage.jobs.count()` and `rule_storage.rules.count()` for post-load log |
| `Instruction` tagged union | `instruction.zig:4-27` | 7 variants (set, rule_set, get, query, remove, remove_rule, list_rules) for DEBUG instruction logging |
| `JobStorage` | `job_storage.zig:7-107` | `.jobs.count()` via `StringHashMapUnmanaged` |
| `RuleStorage` | `rule_storage.zig:7-50` | `.rules.count()` via `StringHashMapUnmanaged` |
| `TcpServer` | `tcp_server.zig:48-114` | `start()` and `handle_connection()` for connection lifecycle logging |

**Sources**: `src/interfaces/config.zig:3-32`, `src/application/scheduler.zig:15-170`, `src/domain/instruction.zig:4-27`, `src/application/job_storage.zig`, `src/application/rule_storage.zig`, `src/infrastructure/tcp_server.zig:48-114`

**Recommendation**:
- Write a `logLevelToStd` mapping function: LogLevel → `std.log.Level` (with `off` → suppress all, `trace` → pass all)
- Use `scheduler.job_storage.jobs.count()` and `scheduler.rule_storage.rules.count()` for startup database state log
- Use `@tagName(instruction)` for DEBUG-level instruction type logging
- The Scheduler needs to expose counts after `load()` — either via public field access or new accessor methods

---

### Q3: [TESTS] What test conventions apply?

**Finding**: The project uses co-located unit tests in `test` blocks and `src/functional_tests.zig` for integration tests. Key patterns:

- **Memory management**: `std.heap.GeneralPurposeAllocator` with `defer _ = gpa.deinit()`, or `std.testing.allocator` for leak detection
- **Assertions**: `std.testing.expect()`, `expectEqual()`, `expectEqualStrings()`, `expectError()`
- **Test helpers**: `build_logfile_bytes()` and `replay_into_scheduler()` in functional_tests.zig
- **String matching**: `std.mem.indexOf()` for substring presence, `std.mem.splitScalar()` for line counting
- **No stderr capture exists**: Current tests validate via response bodies, not output streams

**Challenge for F005**: Testing log output requires capturing stderr or using a writer abstraction. Two approaches:
1. Design `logFn` to write to a configurable `std.io.Writer` (testable with `ArrayList(u8).writer()`)
2. Test at the integration level by running the binary and capturing stderr

**Sources**: `src/functional_tests.zig:16-669`, `src/interfaces/config.zig:129-195`, `src/main.zig:146-240`

**Recommendation**:
- Add unit tests in `main.zig` for the `logLevelToStd` mapping function
- Add unit tests for the custom `logFn` using a buffer writer
- Add functional tests in `functional_tests.zig` for log level filtering behavior
- Follow existing patterns: verbose test names describing behavior, `std.testing.allocator`, string matching with `std.mem.indexOf()`

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**:
- **F005 branch exists** (`feature/F005-add-startup-logging`) at same commit as main (bbecaf5) — no work started yet
- **F004 implementation pattern** (13 files changed): domain → application → infrastructure → docs → tests. F005 differs because logging is a cross-cutting concern primarily in `main.zig`
- **Config parsing already complete**: LogLevel enum, TOML parsing, default `.info`, error handling for invalid values — all tested
- **No competing logging approaches**: No TODOs, FIXMEs, or alternative logging implementations exist
- **Silent error patterns**: Multiple `catch {}` throughout codebase (main.zig:100, tcp_server.zig:43/193/213, execution_client.zig:48) — candidates for logging enhancement

**Sources**: git history, `src/main.zig`, `src/interfaces/config.zig`, `src/infrastructure/tcp_server.zig`

**Recommendation**: F005 can proceed on clean slate. Config infrastructure is ready. Focus implementation on: (1) wiring std_options in main.zig, (2) adding startup log calls, (3) adding runtime log calls in tcp_server.zig and scheduler.zig, (4) updating documentation.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: No dead code found. Cleanup opportunities are all **replacements** within F005 scope:

| File | Line(s) | Issue | Risk |
|------|---------|-------|------|
| `main.zig` | 89 | `std.debug.print("CONTROLLER: start failed...")` → replace with `std.log.err()` | Low |
| `main.zig` | 100 | `scheduler.load(...) catch {}` — silent error swallow → add `std.log.warn()` | Medium |
| `tcp_server.zig` | 43 | `ch.send(response) catch {}` — silent response routing failure → `std.log.warn()` | Medium |
| `tcp_server.zig` | 193, 213 | Silent TCP write failures → `std.log.debug()` | Low |
| `execution_client.zig` | 48 | `self.resolved.append(...) catch {}` — silent OOM → `std.log.err()` | Medium |
| `scheduler.zig` | 265,414,452,491,531,566,607,652 | 8x `deleteFile(...) catch {}` — temp file cleanup → `std.log.debug()` | Low |
| `getting-started.md` | 63 | "No output is expected on startup" — must be updated | Required |

**Sources**: `src/main.zig:89,100`, `src/infrastructure/tcp_server.zig:43,193,213`, `src/application/execution_client.zig:48`, `src/application/scheduler.zig`, `docs/tutorials/getting-started.md:63`

**Recommendation**:
- Priority 1: Replace `std.debug.print` at main.zig:89 and add logging to `scheduler.load() catch {}` at main.zig:100
- Priority 2: Add logging to tcp_server.zig silent catches (connection lifecycle visibility)
- Priority 3 (optional/deferred): Scheduler temp file cleanup and execution_client catch blocks — these are lower value and could bloat scope
- Required: Update getting-started.md documentation

## Best Practices

| Pattern | Application in F005 |
|---------|---------------------|
| Set-before-spawn | Set `runtime_log_level` in main() before spawning threads; no synchronization needed |
| Custom std_options logFn | Define in main.zig root scope; checks runtime variable before formatting |
| LogLevel → std.log.Level mapping | Handle `off` (suppress all) and `trace` (pass all) explicitly; others map by name |
| Exhaustive switch for Instruction logging | Use `@tagName(instruction)` for DEBUG log of received instructions |
| Terse log format | `[INFO] listening on 127.0.0.1:5678` — per spec NFR-003 |
| Co-located unit tests | Add logFn and mapping tests in main.zig test blocks |
| Buffer writer for log testing | Use `ArrayList(u8).writer()` to capture and assert log output in tests |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| std (Zig stdlib) | 0.14.0+ | std.log, std.io, std.fmt | installed | none |

No external dependencies required. F005 uses only Zig stdlib logging facilities.

## References

| File | Relevance |
|------|-----------|
| `src/main.zig` | Primary implementation target — entry point, thread spawning, std_options definition |
| `src/interfaces/config.zig` | LogLevel enum and Config struct (already implemented, reuse as-is) |
| `src/infrastructure/tcp_server.zig` | Connection lifecycle logging (connect/disconnect), silent catch blocks |
| `src/application/scheduler.zig` | Database load logging, job/rule count access, silent catch blocks |
| `src/application/execution_client.zig` | Execution lifecycle logging candidate |
| `src/domain/instruction.zig` | Instruction tagged union for DEBUG-level instruction type logging |
| `src/functional_tests.zig` | Integration test patterns, test helper functions |
| `docs/tutorials/getting-started.md` | Documentation update required (line 63: "no output expected") |
| `docs/reference/configuration.md` | May need log_level documentation update |
