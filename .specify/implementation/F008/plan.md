# Implementation Plan: F008

## Summary

Extract file-based persistence from `Scheduler` into a `LogfilePersistence` struct, introduce a `PersistenceBackend` tagged union with `logfile` and `memory` variants, and add `persistence` config key to `[database]` section. The Scheduler will depend on `PersistenceBackend` instead of direct file operations, and background compression will be skipped for memory backends.

## Constitution Compliance

Constitution: Derived from CLAUDE.md

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal layering (domain/application/infrastructure/interfaces) | COMPLIANT | `PersistenceBackend` and `MemoryPersistence` placed in `src/infrastructure/persistence/backend.zig` |
| Tagged unions for polymorphism | COMPLIANT | `PersistenceBackend = union(enum) { logfile: LogfilePersistence, memory: MemoryPersistence }` — no vtable |
| All union variants declare payloads with `struct {}` syntax | COMPLIANT | Both variants carry structs as payloads |
| Barrel exports per layer | COMPLIANT | `src/infrastructure/persistence.zig` updated to export `backend` |
| Error unions for fallible operations | COMPLIANT | `append` returns `!void`, `load` returns `![][]u8` |
| Persist-before-respond | COMPLIANT | Memory backend `append()` completes before OK response, same codepath as logfile |
| No direct file ops in application layer | COMPLIANT | Scheduler loses all file fields; delegates to `PersistenceBackend` |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.14.0+ |
| Framework | stdlib only (zero external deps) |
| Architecture | 4-layer hexagonal: domain → application → infrastructure → interfaces |
| Key patterns | Tagged unions, error unions, arena allocators, barrel exports, GPA leak detection, co-located tests |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | Should `PersistenceBackend` use methods or free functions? | Methods on the tagged union via `switch(self)` dispatch — consistent with how `Entry` is encoded via `switch(value)` | `encoder.zig:15-22` — `encode()` switches on `Entry` variants |
| A2 | Where does `load_arena` live after extraction? | Inside `LogfilePersistence` — it's specific to file loading (decoding strings from file reads); memory backend doesn't need it | `scheduler.zig:23,65-73` — arena only used in file load path |
| A3 | Should memory backend store `logfile.encode()` output (with framing) or raw `encoder.encode()` output? | Raw encoder output without framing — spec US4 says "identical excluding length-prefix framing" | `logfile.zig:8-13` — framing adds 4-byte prefix that's logfile-specific |
| A4 | How does background compression detect the backend type? | `run_database` checks `PersistenceBackend` variant; only spawns compression process for `.logfile` | `main.zig:147-168` — `run_database` owns scheduler lifecycle and can inspect backend |
| A5 | Should `MemoryPersistence.load()` return owned slices or borrowed? | Return owned `[][]u8` slice of duped entry bytes, caller frees — matches logfile pattern where `parse()` returns owned entries | `logfile.zig:39` — `allocator.dupe()` returns owned copies |
| A6 | What happens when `persistence = "memory"` and `logfile_path` is set? | `logfile_path` is ignored per spec US1-AS3; only `LogfilePersistence` reads it | `config.zig:106-108` — `logfile_path` parsed but only consumed by logfile backend |

## Approach Comparison

| Criteria | Approach A: Tagged union with extracted structs | Approach B: Minimal — optional logfile_path as switch | Approach C: Trait/vtable interface |
|----------|------------------------------------------------|------------------------------------------------------|-----------------------------------|
| Description | Extract `LogfilePersistence` struct, create `MemoryPersistence` struct, wrap in `PersistenceBackend` union | Keep file ops in Scheduler, add `if (persistence == .memory)` guards around file operations | Define interface with function pointers, implementations satisfy the interface |
| Files touched | 5 (backend.zig new, scheduler.zig, config.zig, main.zig, persistence.zig barrel) | 3 (scheduler.zig, config.zig, main.zig) | 6+ (interface.zig, logfile_impl.zig, memory_impl.zig, scheduler.zig, config.zig, main.zig) |
| New abstractions | 1 (PersistenceBackend union) | 0 | 2 (interface + 2 implementations) |
| Risk level | Low | Med (scattered guards, violates hexagonal) | Med (no vtable precedent in codebase) |
| Reversibility | Easy | Easy | Hard |

**Selected: Approach A**
**Rationale:** Follows project's established tagged union pattern (see `Entry`, `Runner`, `Connection` unions). Cleanly separates concerns per hexagonal architecture. Compiler enforces exhaustive handling of future variants.
**Trade-off accepted:** More files touched than Approach B, but gains clean architecture and maintainability. Approach B would scatter persistence guards throughout Scheduler, violating ADR 0001.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| Tagged union over vtable | Codebase uses tagged unions everywhere (`Entry`, `Runner`, `Instruction`); no vtable precedent exists | Vtable — adds indirection, unfamiliar pattern in this codebase |
| `PersistenceBackend` in infrastructure/persistence/ | Persistence is an infrastructure concern; barrel already exports encoder, logfile, background | Application layer — would violate layer direction |
| Memory backend stores raw encoder bytes in `ArrayList([]u8)` | Matches `ArrayListUnmanaged` pattern used in `background.zig:102`; each entry is a separate allocation for clean append/free | Single contiguous buffer — harder to iterate entries on load |
| Config uses `PersistenceMode` enum, not string | Type-safe at parse time; pattern matches `LogLevel` enum parsing | String comparison at runtime — error-prone |
| Scheduler receives `?PersistenceBackend` (optional) | `null` means no persistence (existing behavior when no logfile_path); avoids special "none" variant | Always-present backend — would require a "noop" variant |

## Components

```json
[
  {
    "name": "persistence_backend",
    "project": "",
    "layer": "infrastructure",
    "description": "PersistenceBackend tagged union with LogfilePersistence and MemoryPersistence variants, exposing append/load/deinit methods",
    "files": ["src/infrastructure/persistence/backend.zig", "src/infrastructure/persistence.zig"],
    "tests": ["src/infrastructure/persistence/backend.zig"],
    "dependencies": [],
    "user_story": "US3, US4",
    "verification": {
      "test_command": "zig build test-infrastructure --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "make build"
    }
  },
  {
    "name": "scheduler_refactor",
    "project": "",
    "layer": "application",
    "description": "Remove file-specific fields from Scheduler (logfile_path, logfile_dir, load_arena, fsync_on_persist), replace with optional PersistenceBackend; delegate load/append through backend",
    "files": ["src/application/scheduler.zig"],
    "tests": ["src/application/scheduler.zig"],
    "dependencies": ["persistence_backend"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-application --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "make build"
    }
  },
  {
    "name": "config_persistence_key",
    "project": "",
    "layer": "interfaces",
    "description": "Add PersistenceMode enum and database_persistence field to Config; parse 'persistence' key in [database] section with default 'logfile' and error on invalid values",
    "files": ["src/interfaces/config.zig"],
    "tests": ["src/interfaces/config.zig"],
    "dependencies": [],
    "user_story": "US1, US2",
    "verification": {
      "test_command": "zig build test-interfaces --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "make build"
    }
  },
  {
    "name": "main_wiring",
    "project": "",
    "layer": "interfaces",
    "description": "Construct PersistenceBackend in main() based on config, pass to DatabaseContext and Scheduler; skip background compression for memory backend",
    "files": ["src/main.zig"],
    "tests": ["src/main.zig"],
    "dependencies": ["persistence_backend", "scheduler_refactor", "config_persistence_key"],
    "user_story": "US1, US2",
    "verification": {
      "test_command": "zig build test-all --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "make build"
    }
  },
  {
    "name": "functional_validation",
    "project": "",
    "layer": "interfaces",
    "description": "Functional tests verifying memory backend round-trip (append entries, load, verify), no-file-creation assertion, and existing logfile tests still pass",
    "files": ["src/functional_tests.zig"],
    "tests": ["src/functional_tests.zig"],
    "dependencies": ["scheduler_refactor", "persistence_backend"],
    "user_story": "US1, US2, US4",
    "verification": {
      "test_command": "zig build test-functional --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "make build"
    }
  }
]
```

## Test Plan

### unit_tests

**persistence_backend** (co-located in `backend.zig`):
- `MemoryPersistence`: append entry, load returns stored entries, deinit frees all memory (GPA leak check)
- `MemoryPersistence`: load on empty backend returns empty slice
- `MemoryPersistence`: append multiple entries, load returns all in order
- `MemoryPersistence`: stored bytes match `encoder.encode()` output (format consistency, US4)
- `LogfilePersistence`: append writes framed entry to file, load reads and parses
- `LogfilePersistence`: deinit cleans up arena
- `PersistenceBackend`: dispatch through union for both variants

**config_persistence_key** (co-located in `config.zig`):
- Parse `persistence = "memory"` returns `PersistenceMode.memory`
- Parse `persistence = "logfile"` returns `PersistenceMode.logfile`
- No `persistence` key defaults to `PersistenceMode.logfile`
- Invalid value (e.g., `persistence = "sqlite"`) returns `ConfigError.InvalidValue`

**scheduler_refactor** (co-located in `scheduler.zig`):
- Existing round-trip test adapted to use `PersistenceBackend.logfile`
- New round-trip test with `PersistenceBackend.memory`
- `handle_query` with memory backend persists mutations, skips reads
- Double load with memory backend works without leak

### functional_tests

- Memory backend: append entries via scheduler, load in new scheduler, verify state restored
- Memory backend: confirm no files created in temp directory during operation
- Logfile backend: all existing functional tests pass unchanged

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Existing scheduler tests break during refactoring | High | P1 | Refactor incrementally: extract LogfilePersistence first (pure move), run tests, then introduce union | Developer |
| Background compression thread accesses stale backend reference | Low | P0 | Background compression already receives `dir` as parameter; gate on backend variant in `run_database` before spawning | Developer |
| Memory leak in MemoryPersistence.deinit | Med | P1 | Every test uses GPA with strict `deinit()` assertion; test append+deinit explicitly | Developer |
| Config backward compatibility regression | Low | P1 | Existing config tests run unchanged; default `persistence` is `logfile` | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| `scheduler.zig` fields: `logfile_path`, `logfile_dir`, `load_arena`, `fsync_on_persist` | Moved into `LogfilePersistence` | Delete from Scheduler struct |
| `scheduler.zig:append_to_logfile()` | Logic moved to `LogfilePersistence.append()` | Delete method |
| `scheduler.zig:load()` file operations | Logic moved to `LogfilePersistence.load()` and `PersistenceBackend.load()` | Replace with backend delegation |
| `main.zig:DatabaseContext` fields: `logfile_path`, `logfile_dir`, `fsync_on_persist` | Replaced by `PersistenceBackend` field | Delete fields, add `persistence: ?PersistenceBackend` |
