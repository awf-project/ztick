# F008: Add In-Memory Persistence Backend

## Scope

### In Scope

- Tagged union `PersistenceBackend` abstracting persistence strategy behind a common interface
- `MemoryPersistence` implementation storing encoded entries in an in-memory `ArrayList`
- Extraction of existing file-based persistence from `Scheduler` into `LogfilePersistence`
- `persistence` configuration key in `[database]` section with `"logfile"` (default) and `"memory"` values
- Scheduler refactoring to depend on `PersistenceBackend` instead of direct file operations
- Conditional compression: background compressor skipped when backend is `memory`

### Out of Scope

- SQLite or other database-backed persistence backends
- Remote/networked persistence (Redis, etcd)
- Runtime switching between persistence backends (requires restart)
- Data export from memory backend to logfile format

### Deferred

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| SQLite persistence backend | Tagged union design supports future variants but SQLite adds external dependency complexity | future |
| Memory-to-logfile export/dump | Useful but not required for core memory backend value | future |
| Persistence backend hot-swap | Would require scheduler pause/drain protocol not yet designed | future |

---

## User Stories

### US1: Run ztick with in-memory persistence (P1 - Must Have)

**As a** ztick operator,
**I want** to configure ztick to use in-memory persistence,
**So that** I can run ztick without any disk I/O for ephemeral deployments, CI environments, and development.

**Why this priority**: This is the core value proposition — enabling ztick to run without filesystem dependency. Without this, the feature has no reason to exist.

**Acceptance Scenarios:**
1. **Given** a config file with `[database]` containing `persistence = "memory"`, **When** ztick starts, **Then** the scheduler operates without creating or reading any files on disk.
2. **Given** a config file with `persistence = "memory"`, **When** a `SET` command is sent and the job fires, **Then** the job executes correctly despite no disk-backed persistence.
3. **Given** a config file with `persistence = "memory"` and `logfile_path = "some/path"`, **When** ztick starts, **Then** `logfile_path` and `fsync_on_persist` are ignored and no file is created at that path.
4. **Given** a config file with `persistence = "memory"`, **When** ztick is stopped and restarted, **Then** no previously scheduled jobs or rules are restored (data is ephemeral).

**Independent Test:** Start ztick with `persistence = "memory"` in a temporary directory, send SET and RULE SET commands, verify execution occurs, then confirm no files were created in the directory.

### US2: Backward-compatible default to logfile persistence (P1 - Must Have)

**As a** ztick operator with an existing deployment,
**I want** ztick to default to logfile persistence when no `persistence` key is configured,
**So that** upgrading to this version does not change behavior or require config changes.

**Why this priority**: Breaking existing deployments would be unacceptable. The default must preserve current behavior exactly.

**Acceptance Scenarios:**
1. **Given** a config file with no `persistence` key in `[database]`, **When** ztick starts, **Then** it uses logfile persistence identically to the current behavior.
2. **Given** a config file with `persistence = "logfile"` and `logfile_path = "data.log"`, **When** ztick starts, **Then** it reads from and appends to `data.log` as before.
3. **Given** no config file at all, **When** ztick starts with defaults, **Then** logfile persistence is used with the default logfile path.

**Independent Test:** Run the existing test suite without any config changes and verify all tests pass with identical behavior.

### US3: Scheduler decoupled from file-based persistence (P2 - Should Have)

**As a** ztick developer,
**I want** the scheduler to interact with persistence through an abstraction rather than directly manipulating files,
**So that** the scheduler is easier to test, reason about, and extend with new backends.

**Why this priority**: This is an architectural improvement that enables the memory backend and future backends. It is the prerequisite refactoring, but users do not directly interact with it.

**Acceptance Scenarios:**
1. **Given** the refactored scheduler, **When** inspecting `scheduler.zig`, **Then** it contains no direct file operations (`openFile`, `createFile`, `write`, `read`) — all persistence goes through `PersistenceBackend`.
2. **Given** the refactored scheduler, **When** running `make test`, **Then** all existing tests pass without modification to their assertions.

**Independent Test:** Run `make test-application` and `make test-functional` — all pass. Grep `scheduler.zig` for direct file operations — none found.

### US4: Memory backend preserves binary encoding format (P3 - Nice to Have)

**As a** ztick developer,
**I want** the memory backend to store entries in the same binary encoding as the logfile backend,
**So that** future features like memory-to-file export use a consistent format without transcoding.

**Why this priority**: Format consistency is a design quality that pays off later but is not user-visible today.

**Acceptance Scenarios:**
1. **Given** a memory backend with stored entries, **When** comparing the encoded bytes to what the logfile backend would write, **Then** they are identical (excluding length-prefix framing).

**Independent Test:** Encode an entry, append to both backends, compare the raw bytes stored by the memory backend against the encoder output.

### Edge Cases

- What happens when `persistence = "memory"` and a `QUERY` or `LISTRULES` command is sent on an empty scheduler? Returns empty results, same as logfile backend with no prior data.
- What happens when `persistence` is set to an unrecognized value (e.g., `persistence = "sqlite"`)? Config parser returns a `ConfigError` with the invalid value.
- What happens when the memory backend runs out of memory during `append`? The `OutOfMemory` error propagates through the error union, same as any allocation failure in the scheduler.
- What happens when background compression runs with a memory backend? The compressor is skipped entirely — no-op for non-logfile backends.
- What happens when `persistence = "logfile"` but `logfile_path` is not set? Current default behavior applies — uses default logfile path.

---

## Requirements

### Functional Requirements

- **FR-001**: System MUST support a `persistence` configuration key in `[database]` accepting values `"logfile"` and `"memory"`.
- **FR-002**: System MUST default to `"logfile"` persistence when the `persistence` key is absent from configuration.
- **FR-003**: System MUST reject unrecognized `persistence` values with a `ConfigError` at startup.
- **FR-004**: System MUST store all mutation entries (SET, RULE SET, REMOVE, REMOVERULE) in the memory backend when `persistence = "memory"`.
- **FR-005**: System MUST NOT create, read, or write any files when `persistence = "memory"`, regardless of `logfile_path` or `fsync_on_persist` values.
- **FR-006**: System MUST load previously persisted entries on startup when `persistence = "logfile"`, preserving current behavior exactly.
- **FR-007**: System MUST skip background compression when the persistence backend is `memory`.
- **FR-008**: System MUST expose a `PersistenceBackend` tagged union with `append`, `load`, and `deinit` methods.
- **FR-009**: System MUST free all memory-backend entries on `deinit`, leaving no leaked allocations.

### Non-Functional Requirements

- **NFR-001**: Memory backend `append` operation completes in O(1) amortized time (ArrayList append).
- **NFR-002**: No regression in existing logfile persistence performance — the abstraction layer adds zero overhead for the logfile path when the backend variant is known.
- **NFR-003**: All existing tests pass without modification after the refactoring.
- **NFR-004**: No secrets, file paths, or persistence internals exposed in error messages to TCP clients.

---

## Success Criteria

- **SC-001**: `ztick` starts and processes jobs correctly with `persistence = "memory"` — zero files created during operation.
- **SC-002**: Existing configurations without a `persistence` key produce identical behavior to the pre-feature version — all existing tests pass.
- **SC-003**: `scheduler.zig` contains zero direct file I/O operations — all persistence routed through `PersistenceBackend`.
- **SC-004**: Memory backend round-trip test (append N entries, load, verify all N entries returned) passes with zero memory leaks under `zig test` leak detection.
- **SC-005**: Config parser rejects invalid `persistence` values and provides a clear error message.

---

## Key Entities

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| PersistenceBackend | Tagged union abstracting storage strategy | variants: `logfile`, `memory`; methods: `append`, `load`, `deinit` |
| MemoryPersistence | In-memory storage of encoded persistence entries | `entries: ArrayListUnmanaged([]u8)`, `allocator: Allocator` |
| LogfilePersistence | File-based append-only persistence (extracted from Scheduler) | `logfile_path`, `logfile_dir`, `fsync_on_persist`, `load_arena` |
| Entry | Domain entity representing a persisted mutation | type byte, encoded payload (job, rule, job_removal, rule_removal) |

---

## Assumptions

- The Scheduler currently tolerates missing `logfile_path` by skipping persistence — this behavior maps cleanly to the memory backend.
- The `load_arena` allocator pattern is specific to the logfile backend (keeping decoded strings alive from file reads) and does not apply to the memory backend.
- Background compression (`background.zig`) already has a reference to the scheduler or persistence path that can be conditionally checked.
- The binary encoding format produced by the encoder is stable and suitable for in-memory storage without the length-prefix framing.
- Three-thread architecture and channel-based communication are unaffected — persistence backend is accessed only from the database thread.

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: medium
- **Estimation**: L

## Dependencies

- **Blocked by**: none
- **Unblocks**: none

## Clarifications

_Section populated during clarify step with resolved ambiguities._

## Notes

- Implementation order: extract `LogfilePersistence` first (pure refactoring, no behavior change), then introduce `PersistenceBackend` union and `MemoryPersistence`, then config parsing and wiring.
- Tagged union chosen over vtable for idiomatic Zig — enables comptime dispatch when variant is known, simpler to extend.
- Memory backend stores the same encoded bytes as logfile (encoder output) without length-prefix framing, maintaining format consistency across backends.
- The `load_arena` becomes an internal detail of `LogfilePersistence` rather than a Scheduler field.
- Compression is logfile-specific: memory entries are already deduplicated by the scheduler's in-memory HashMap (overwrites by key), making compression meaningless.
