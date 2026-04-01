# Research: F008 - Add In-Memory Persistence Backend

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig 0.14.0+ |
| Domain | CLI / scheduler |
| Task Type | feature (refactor + new variant) |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: Project memories provide extensive context for F008:

1. **Architecture Decisions (ADRs 1-49)**: The project follows strict 4-layer hexagonal architecture (domain -> application -> infrastructure -> interfaces). All persistence code lives in `src/infrastructure/persistence/`. Tagged unions are the idiomatic pattern for polymorphism (ADRs 39, 43, 46). No vtables - comptime dispatch preferred.

2. **Implementation Patterns**: Key patterns applicable to F008:
   - Pattern 6: Binary codec with length-prefixed entries, type byte discriminators
   - Pattern 12: Cross-layer ownership transfer (allocate in app, free in infra)
   - Pattern 21: Removal as tagged union variant extension with exhaustive switch enforcement
   - Pattern 25: Persist-before-respond for mutation commands
   - Pattern 26: Empty struct payloads for consistent tagged union destructuring

3. **Feature Roadmap**: F001-F007 all IMPLEMENTED. F008 is the next feature. No blockers.

4. **Test Conventions**: Co-located unit tests, functional_tests.zig for integration, GPA leak detection, tmpDir for file isolation, build_logfile_bytes helper for persistence tests.

**Sources**: architecture_decisions.md, implementation_patterns.md, feature_roadmap.md, test_conventions.md
**Recommendation**: Follow tagged union pattern (not vtable) for PersistenceBackend. Place new code in infrastructure/persistence/. Use existing encoder.encode() for both backends.

---

### Q1: [ARCH] What patterns should F008 follow?

**Finding**: The codebase has a clean 4-layer hexagonal architecture. Persistence currently lives in `src/infrastructure/persistence/` with three modules: `encoder.zig` (binary encoding), `logfile.zig` (length-prefix framing), `background.zig` (compression). The Scheduler in `src/application/scheduler.zig` directly performs file I/O through two methods:

- `load()` (lines 46-79): Opens file, reads entire content, parses frames, decodes entries, replays via `replay_entry()`
- `append_to_logfile()` (lines 102-138): Constructs Entry from Request, encodes, frames, opens/creates file, seeks to end, writes, optionally syncs

Scheduler holds file-related fields directly (lines 15-24): `logfile_path`, `logfile_dir`, `load_arena`, `fsync_on_persist`.

Config parsing in `src/interfaces/config.zig` handles `[database]` section (lines 93-112) with keys: `fsync_on_persist`, `framerate`, `logfile_path`. No `persistence` key exists yet.

Main wiring in `src/main.zig` constructs `DatabaseContext` (lines 118-129) with logfile fields and passes to `run_database()` (lines 147-168).

**Sources**: `src/application/scheduler.zig:15-138`, `src/interfaces/config.zig:20-112`, `src/main.zig:118-168`, `src/infrastructure/persistence/`

**Recommendation**:
1. Create `src/infrastructure/persistence/backend.zig` with `PersistenceBackend` tagged union (`logfile`, `memory` variants)
2. Extract `LogfilePersistence` struct from Scheduler's file operations
3. Implement `MemoryPersistence` struct with `ArrayListUnmanaged([]u8)`
4. Both variants expose `append()`, `load()`, `deinit()` methods
5. Scheduler replaces file fields with `persistence: ?PersistenceBackend`
6. Config adds `persistence` key defaulting to `"logfile"`

---

### Q2: [TYPES] Which types can F008 reuse?

**Finding**: Several existing types are directly reusable:

| Type | Location | Reuse |
|------|----------|-------|
| `Entry` (tagged union) | `src/infrastructure/persistence/encoder.zig:8-13` | YES - core persisted type with 4 variants (job, rule, job_removal, rule_removal) |
| `encoder.encode()` | `src/infrastructure/persistence/encoder.zig:15` | YES - produces binary bytes for both backends |
| `encoder.decode()` | `src/infrastructure/persistence/encoder.zig:24` | YES - parses binary back to Entry |
| `encoder.free_entry_fields()` | `src/infrastructure/persistence/encoder.zig:224` | YES - cleanup for decoded entries |
| `logfile.encode()` | `src/infrastructure/persistence/logfile.zig:8` | LogfilePersistence ONLY - adds length-prefix framing |
| `logfile.parse()` / `ParseResult` | `src/infrastructure/persistence/logfile.zig:16-21` | LogfilePersistence ONLY - strips length prefixes |
| `Job`, `Rule` | `src/domain/job.zig:10-14`, `src/domain/rule.zig:6-17` | YES - referenced by Entry variants |
| `Config` struct | `src/interfaces/config.zig:20-36` | MODIFY - add `database_persistence` field |
| `JobStorage`, `RuleStorage` | `src/application/job_storage.zig`, `rule_storage.zig` | NO change needed |

**Key distinction**: Memory backend stores raw `encoder.encode()` output (without logfile framing). Logfile backend stores `logfile.encode(encoder.encode())` output (with 4-byte length prefix).

**Sources**: `src/infrastructure/persistence/encoder.zig:8-224`, `src/infrastructure/persistence/logfile.zig:8-21`, `src/domain/job.zig:10-14`, `src/domain/rule.zig:6-17`

**Recommendation**:
- Create `PersistenceBackend` tagged union with `logfile: LogfilePersistence` and `memory: MemoryPersistence` variants
- Create `MemoryPersistence` struct: `entries: ArrayListUnmanaged([]u8)`, `allocator: Allocator`
- Create `LogfilePersistence` struct: `logfile_path`, `logfile_dir`, `fsync_on_persist`, `load_arena`
- Add `PersistenceType = enum { logfile, memory }` to config module

---

### Q3: [TESTS] What test conventions apply?

**Finding**: The project has well-established test patterns:

1. **Unit tests** (co-located): Scheduler tests at `src/application/scheduler.zig:255-765` use GPA with strict leak assertion. Persistence round-trip test (lines 255-305) creates temp file, persists SET/RULE_SET, reloads in new scheduler, verifies state. Double-load test (lines 478-517) verifies arena cleanup.

2. **Encoder tests**: `src/infrastructure/persistence/encoder.zig:246-368` - encode/decode with exact byte comparison via `expectEqualSlices()`. Golden test data as fixed byte arrays.

3. **Logfile framing tests**: `src/infrastructure/persistence/logfile.zig:47-137` - length-prefix encode/decode, partial frame handling.

4. **Config tests**: `src/interfaces/config.zig:149-250` - parse TOML strings, `expectError()` for invalid values, verify defaults for missing keys.

5. **Background compression tests**: `src/infrastructure/persistence/background.zig:167-300+` - use `std.testing.tmpDir()` for isolation, verify deduplication and removal exclusion.

6. **Functional tests**: `src/functional_tests.zig` - process-based tests with `build_logfile_bytes()` and `replay_into_scheduler()` helpers.

7. **Leak detection**: GPA with `defer { status = gpa.deinit(); std.debug.assert(status == .ok); }` pattern.

**Sources**: `src/application/scheduler.zig:255-765`, `src/infrastructure/persistence/encoder.zig:246-368`, `src/interfaces/config.zig:149-250`, `src/functional_tests.zig`

**Recommendation**: F008 tests must include:
- Memory backend unit tests: append, load (empty), deinit (leak-free) with GPA assertion
- Round-trip test: encode entry -> memory.append() -> verify stored bytes match encoder output
- Config tests: `persistence="memory"` parsing, invalid value rejection, default to `"logfile"`
- Scheduler integration: handle_query with memory backend, verify no file created
- Functional test: start ztick with `persistence="memory"`, send SET, verify execution, confirm no disk files

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: Git history reveals the persistence evolution:

1. **Initial implementation** (commit a626740): Established file-based persistence directly coupled to Scheduler with load()/append_to_logfile() methods, ArenaAllocator for loading, and optional logfile_path.

2. **F003 removal entries** (commit 1e4333e): Extended persistence with type bytes 2-3 (job_removal, rule_removal). Changes touched encoder.zig, background.zig, and scheduler.zig. Demonstrates how persistence extensions propagate across layers.

3. **F007 dump command** (commit e7ab883): Added logfile inspection with sequential frame reading. Created dump.zig with text/JSON/compact/follow modes. Duplicated deduplication logic from background.zig.

4. **No existing polymorphism precedent**: The codebase has no trait/interface pattern for persistence. Tagged unions are used for domain types (Runner, Instruction, Entry, Connection) but not yet for infrastructure abstractions. F008 establishes the first infrastructure-level tagged union.

5. **Configuration precedent**: Config system is extensible. TLS (F006) added `tls_cert`/`tls_key` with pair validation. F008 follows same pattern adding `persistence` key.

**Sources**: Git history (commits a626740, 1e4333e, e7ab883), `docs/ADR/`

**Recommendation**: Follow the F003 extension pattern - update encoder, scheduler, and config in coordinated fashion. Use tagged union (not vtable) consistent with Connection union from F006. Extract LogfilePersistence first as pure refactoring before adding MemoryPersistence.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: Five cleanup opportunities identified:

| # | Category | Location | Description | Impact |
|---|----------|----------|-------------|--------|
| 1 | Replaceable | `scheduler.zig:50,56,130-137` | 7 direct file I/O operations (openFile, readToEndAlloc, seekFromEnd, writeAll, sync) | High - blocks abstraction |
| 2 | Replaceable | `scheduler.zig:20-24,34,43,65-73` | load_arena + logfile fields tightly coupled to Scheduler (6 references) | High - memory mgmt complexity |
| 3 | Duplication | `background.zig:75-115` + `dump.zig:173-198` | Identical deduplication algorithm (build last_index map, build removed_ids set, filter) | High - 80+ duplicated lines |
| 4 | Replaceable | `scheduler.zig:20`, `main.zig:121,515`, `config.zig:28,106-108` | logfile_path flows through 5 files / 11 references | High - architectural coupling |
| 5 | Replaceable | `scheduler.zig:263-765` | 14 test file operations use cwd() instead of tmpDir() | Medium - test hygiene |

**Not found**: No dead code, no unused imports in scheduler.zig, no TODO/FIXME markers in affected files.

**Sources**: `src/application/scheduler.zig:20-765`, `src/infrastructure/persistence/background.zig:75-115`, `src/interfaces/dump.zig:173-198`, `src/main.zig:118-515`

**Recommendation**:
- Phase 1: Extract LogfilePersistence from Scheduler (removes findings 1, 2, 4 - ~100 lines moved)
- Phase 2: Scheduler depends on PersistenceBackend abstraction instead of direct file ops
- Deduplication consolidation (finding 3) is valuable but can be deferred - it's not required by F008 spec and risks scope creep
- Test migration to tmpDir (finding 5) should happen naturally when tests are updated for the new abstraction

---

## Best Practices

| Pattern | Application in F008 |
|---------|----------------------------|
| Tagged union dispatch | `PersistenceBackend = union(enum) { logfile: LogfilePersistence, memory: MemoryPersistence }` - no vtable, comptime optimization |
| Empty struct payloads | All union variant payloads use `struct {}` syntax per CLAUDE.md |
| Explicit allocator passing | MemoryPersistence takes Allocator parameter; LogfilePersistence manages load_arena internally |
| Error union propagation | Both variants return errors through `!void` / `!LoadResult` unions |
| Exhaustive switch | Adding variants to PersistenceBackend forces handling in all switch sites |
| Persist-before-respond | Memory backend append() must complete before OK response, same as logfile |
| Arena allocator for loading | LogfilePersistence owns load_arena; MemoryPersistence needs no arena (data already allocated) |
| Set-before-spawn config | Persistence backend constructed in main() before thread spawn |
| Barrel exports | Add `backend` to `src/infrastructure/persistence.zig` barrel |
| GPA leak detection | All new tests use GPA with strict deinit assertion |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| zig | 0.14.0+ | Language/compiler | installed | none |
| std | (stdlib) | ArrayList, Allocator, fs, testing | installed | none |

No external dependencies required. Zero-dependency invariant preserved.

## References

| File | Relevance |
|------|-----------|
| `src/application/scheduler.zig` | Primary refactoring target - extract file ops into LogfilePersistence |
| `src/infrastructure/persistence/encoder.zig` | Binary encoding shared by both backends - Entry type definition |
| `src/infrastructure/persistence/logfile.zig` | Length-prefix framing used by LogfilePersistence only |
| `src/infrastructure/persistence/background.zig` | Compression must be conditionally skipped for memory backend |
| `src/interfaces/config.zig` | Add `persistence` key parsing in [database] section |
| `src/main.zig` | Wiring: construct PersistenceBackend, pass to DatabaseContext |
| `src/infrastructure/persistence.zig` | Barrel export - add backend module |
| `src/infrastructure.zig` | Layer barrel - may need update |
| `src/interfaces/dump.zig` | Reference for deduplication pattern; not modified by F008 |
| `src/functional_tests.zig` | Add memory backend integration tests |
