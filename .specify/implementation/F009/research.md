# Research: F009 - Background Compression Scheduling

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig |
| Domain | Time-based job scheduler (hexagonal architecture) |
| Task Type | Feature (wiring existing infrastructure into runtime) |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: Extensive prior work documented across claude-mem sessions (S460-S465) and project memory files. Key facts:
- ADR-55 (F008): "Skip background compression for memory backend" — confirms the conditional guard pattern F009 must implement
- ADR-50: PersistenceBackend is a tagged union `{ logfile: LogfilePersistence, memory: MemoryPersistence }` — F009 switches on this tag
- Pattern-56: "Variant-gated background work" — check PersistenceBackend variant before spawning background work; only `.logfile` triggers disk-based operations
- Pattern-51: "Persistence backend extraction" — Scheduler lost file fields, gained `?PersistenceBackend`; backend methods encapsulate variant-specific logic
- Session S462 (#17515): TODO file created documenting F009 scope, infrastructure inventory, open questions, and files affected
- Sessions S460-S461 (#17512-17514): Confirmed compression infrastructure is fully implemented and tested but completely unwired in runtime; `_ = infrastructure_persistence_background` suppresses unused import warning

**Sources**: `architecture_decisions.md`, `implementation_patterns.md`, `test_conventions.md`, claude-mem sessions S460-S465 (#17512-17517)

**Recommendation**: Follow established Pattern-56 (variant-gated background work) and ADR-55 (skip compression for memory). The implementation is purely wiring — no algorithm changes needed.

---

### Q1: [ARCH] What patterns should F009 follow?

**Finding**: F009 spans all four hexagonal layers. Integration points identified:

1. **Interfaces** (`src/interfaces/config.zig`): Add `database_compression_interval` field to Config struct (lines 25-42). Parse in database section handler (lines 100-121). Follow `framerate` parsing pattern (lines 109-112) for u32 validation.

2. **Application** (`src/application/scheduler.zig`): Add CompressionScheduler fields to Scheduler struct (line 16). Integrate time-based trigger into `tick(current_time: i64)` method (line 99). The tick loop already receives nanosecond timestamps — use `current_time - last_compression_time >= interval_ns` for trigger decision.

3. **Infrastructure** (`src/infrastructure/persistence/background.zig`): Reuse `Process` executor (lines 14-44) and `compress()` function (lines 52-124) as-is. `Process.status()` (line 38) uses mutex — safe for concurrent polling from tick loop.

4. **Interfaces/Wiring** (`src/main.zig`): Replace `_ = infrastructure_persistence_background` suppression (line 92) with actual usage. Pass compression config to database thread via `run_database()` (lines 147-168). `TickContext.tick()` at line 187 provides the nanosecond timestamp entry point.

**Reference implementations**:
- F008 PersistenceBackend integration: `src/main.zig:620-631` (backend construction from config)
- Tick loop with time tracking: `src/application/scheduler.zig:99` + `src/main.zig:187`

**Sources**: `src/main.zig`, `src/application/scheduler.zig`, `src/interfaces/config.zig`, `src/infrastructure/persistence/background.zig`, `src/infrastructure/persistence/backend.zig`

**Recommendation**: Place scheduling state machine (timer, trigger, spawn) in `application/scheduler.zig`. Keep all file I/O and threading in infrastructure layer via existing `Process` executor. Config extension in interfaces layer. Wiring in `main.zig`.

---

### Q2: [TYPES] Which types can F009 reuse?

**Finding**: Complete type inventory — all core types exist and require no modification:

| Type | Location | Status |
|------|----------|--------|
| `Process` | `background.zig:14-44` | Reuse as-is. Thread-spawning executor with mutex-guarded result, execute/status/deinit methods |
| `Status` | `background.zig:8-12` | Reuse as-is. `union(enum) { success, failure: TaskError, running }` |
| `TaskError` / `TaskResult` | `background.zig:5-6` | Reuse as-is. Standard error types for background tasks |
| `Filenames` | `background.zig:46-50` | Reuse as-is. Pre-defined source/tmp/dest paths for compression staging |
| `compress()` | `background.zig:52-124` | Reuse as-is. Two-pass deduplication algorithm |
| `PersistenceBackend` | `backend.zig:81-120` | Reuse as-is. Tagged union for conditional guard dispatch |
| `LogfilePersistence` | `backend.zig:6-50` | Reuse as-is. Contains `logfile_path`, `logfile_dir` needed for compression |
| `MemoryPersistence` | `backend.zig:52-79` | Reuse as-is. Skip compression for this variant |
| `Config` | `config.zig:25-42` | **Extend**: Add `database_compression_interval: u32` field |
| `PersistenceMode` | `config.zig:12-15` | Reuse as-is. Gates whether compression is applicable |
| `ConfigError` | `config.zig:17-23` | Reuse as-is. For invalid compression_interval values |
| `Clock` | `clock.zig:3-18` | Reuse as-is. Framerate-based tick scheduling |
| `Scheduler` | `scheduler.zig:16-21` | **Extend**: Add compression scheduling fields (interval, last_run, active_process) |

**Types to create**:
- No new types strictly needed. Compression scheduling state can be added as fields directly on `Scheduler` struct, or as a small `CompressionScheduler` struct if cleaner. Decision depends on field count.

**Sources**: `src/infrastructure/persistence/background.zig`, `src/infrastructure/persistence/backend.zig`, `src/interfaces/config.zig`, `src/infrastructure/clock.zig`, `src/application/scheduler.zig`

**Recommendation**: Extend `Config` with one new field and `Scheduler` with 3 fields (interval_ns, last_compression_ns, active_process). No new type definitions needed — compose existing types.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Well-established test patterns must be followed:

1. **Naming**: `test "lowercase descriptive phrase"` — name after observable behavior, not implementation internals
2. **Allocators**: `std.testing.allocator` for simple tests; `std.heap.GeneralPurposeAllocator` for complex tests with leak detection
3. **Temporary directories**: `var tmp = std.testing.tmpDir(.{}); defer tmp.cleanup();` — all file I/O via `tmp.dir`
4. **Assertions**: `expectEqual()`, `expectEqualStrings()`, `expectEqualSlices()`, `expect()`, `expectError()`
5. **File existence**: `tmp.dir.statFile()` for exists, `expectError(error.FileNotFound, ...)` for absent
6. **Threading**: `std.atomic.Value(bool)` gates for visibility; `std.Thread.sleep()` for timing
7. **Co-located tests**: Unit tests in same file as implementation (background.zig has 7 existing tests at lines 126-298)
8. **Functional tests**: Cross-layer integration in `src/functional_tests.zig`

**Existing compression test patterns** (background.zig):
- Create entries via `encoder.encode()` → frame via `logfile.encode()` → write to tmpdir file
- Call `compress()` → read destination file → parse with `logfile.parse()` → assert entry count/content
- Assert file lifecycle: source deleted (`expectError(FileNotFound)`), destination exists (`statFile()`)

**Test helpers available**:
- `build_logfile_bytes()` (functional_tests.zig:160) — builds framed logfile entries
- `replay_into_scheduler()` (functional_tests.zig:175) — parses and replays entries
- `spawn_ztick()` (functional_tests.zig:642) — CLI process spawning
- `TestServer` struct (functional_tests.zig:690) — full server lifecycle management

**Sources**: `src/infrastructure/persistence/background.zig:126-298`, `src/functional_tests.zig:160-725`, `src/application/scheduler.zig` (test blocks)

**Recommendation**: Add unit tests for compression scheduling logic in `scheduler.zig` (timer trigger, skip when running, skip for memory backend). Add functional tests in `functional_tests.zig` for end-to-end compression cycle (start scheduler → wait interval → verify compressed file). Use `TestServer` pattern for process-based tests.

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: Six historical decisions directly constrain F009:

| Decision | Source | Constraint |
|----------|--------|-----------|
| F008 PersistenceBackend union (commit 4abbf35) | `backend.zig` | Must gate compression via `switch (.logfile/.memory)` |
| Existing compress() + Process (commit a626740) | `background.zig` | No modifications allowed; reuse as-is per spec assumption |
| Config parser infrastructure (F008) | `config.zig` | Ready for `compression_interval`; follow `framerate` parsing pattern |
| Hexagonal architecture (ADR-0001) | Architecture | Scheduling in Application, threading in Infrastructure |
| Three-thread concurrency model | CLAUDE.md | Compression timer lives in Database thread (tick loop) |
| Append-only logfile design | Persistence layer | Rotation via atomic rename; `LogfilePersistence.append()` auto-creates fresh file |

**Key pitfalls from history**:
- Never `join()` compression thread during shutdown (FR-005) — use `status()` polling only
- File rotation rename must complete in <1ms (NFR-002) — POSIX atomic rename guarantees this
- Check backend variant early to avoid unnecessary allocations (NFR-003 zero overhead for memory)
- Handle leftover `.to_compress` files at startup (FR-009) — from interrupted prior compression

**Sources**: ADR-0001, ADR-0002, CLAUDE.md, commits 4abbf35 and a626740, `.agent/todo/add-background-compression-scheduling.md`

**Recommendation**: Follow F008's integration pattern exactly: parse config → construct state → conditional switch on tag. The `Process` executor's `status()` method is the safe polling mechanism — never block on `join()`.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: Three cleanup items identified, all low risk:

| Item | File:Line | Category | Risk |
|------|-----------|----------|------|
| Import suppression `_ = infrastructure_persistence_background` | `src/main.zig:92` | REPLACEABLE | LOW |
| Unused import declaration | `src/main.zig:22` | REPLACEABLE | LOW |
| Public barrel export (currently unused) | `src/infrastructure/persistence.zig:3` | REPLACEABLE | LOW |

**No dead code to remove**: All code in `background.zig` is intentional infrastructure awaiting F009 wiring. All 7 test blocks remain valid.

**No TODO/FIXME/HACK markers** found in the persistence layer or main.zig related to compression.

**Potential future consolidation** (not for F009): File operation patterns between `background.zig` (compress) and `backend.zig` (LogfilePersistence) share `createFile`/`rename` patterns. Not worth extracting now — only 2 consumers.

**Sources**: `src/main.zig:22,92`, `src/infrastructure/persistence.zig:3`

**Recommendation**: During F009 implementation, replace the `_ =` suppression on main.zig:92 with actual usage of the background module. The import on line 22 stays but gets used. All existing background.zig tests must continue passing (SC-005).

## Best Practices

| Pattern | Application in F009 |
|---------|---------------------|
| Variant-gated background work (Pattern-56) | Check `PersistenceBackend` tag before spawning compression; `.memory` = no-op with zero overhead |
| Config enum with default fallback (Pattern-55) | Parse `compression_interval` from TOML with default 3600, value 0 = disabled |
| Set-before-spawn runtime configuration (Pattern-32) | Set compression interval in main() before spawning database thread |
| Exhaustive switch cascade (Pattern-13) | Any new tagged union variant forces compiler-checked handling at all dispatch sites |
| Process-based functional tests (Pattern-35) | Spawn ztick with compression config, verify compressed file creation after interval |
| Atomic rename for persistence writes (CLAUDE.md) | Rotate active logfile to `.to_compress` via `std.fs.Dir.rename()` |
| Non-blocking try_send (Pattern-33) | Compression status polling must never block the tick loop |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| Zig stdlib | 0.14.0+ | All functionality (threads, filesystem, atomics, time) | installed | none |

No external dependencies required. F009 uses only Zig stdlib per ADR-0002.

## References

| File | Relevance |
|------|-----------|
| `src/infrastructure/persistence/background.zig` | Core compression algorithm and Process executor — reuse as-is |
| `src/application/scheduler.zig` | Tick loop where compression timer logic will be added |
| `src/interfaces/config.zig` | Config struct to extend with compression_interval |
| `src/main.zig` | Wiring point: replace import suppression with actual usage |
| `src/infrastructure/persistence/backend.zig` | PersistenceBackend tagged union for conditional guard |
| `src/infrastructure/clock.zig` | Clock struct driving the tick loop at configured framerate |
| `src/functional_tests.zig` | Integration test patterns and helpers (TestServer, build_logfile_bytes) |
| `.specify/implementation/F009/spec-content.md` | Feature specification with 10 FRs, 4 NFRs, 5 SCs |
| `.agent/todo/add-background-compression-scheduling.md` | Prior analysis documenting scope and open questions |
