# F009: Background Compression Scheduling

## Scope

<!--
  Define what this feature covers and what it explicitly does NOT cover.
  This prevents scope creep and sets clear boundaries for implementation.
-->

### In Scope

- Wire `background.compress()` into the runtime tick loop with time-based trigger policy
- Add `compression_interval` configuration key to `[database]` section
- Conditional guard: run compression only for `.logfile` backend, skip for `.memory` backend
- Thread lifecycle management for compression process (spawn, status poll, join, cleanup)
- File preparation: atomic rename of active logfile to `.to_compress` before compression starts
- Coordinator lock: prevent concurrent logfile writes during the rename window

### Out of Scope

- Mutation-count threshold triggering (hybrid policy deferred)
- Compression progress reporting or metrics endpoint
- Multi-file compression (compressing already-compressed files into further-compacted form)
- Changes to the `compress()` algorithm itself or `Process` executor

### Deferred

<!--
  Track work that was considered but intentionally postponed.
  Each item must have a rationale to prevent scope amnesia.
-->

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| Mutation-count trigger | Timer-based is simpler to implement and reason about; count-based adds scheduler coupling | future |
| Compression disable toggle | Interval of 0 or omitted key serves as implicit disable; explicit boolean adds config surface without clear value | future |
| Compressed file reload | Scheduler already deduplicates on load via replay; compacted file is a storage optimization, not a load optimization | future |

---

## User Stories

<!--
  User stories are PRIORITIZED vertical slices ordered by importance.
  Each story must be INDEPENDENTLY TESTABLE - implementing just ONE
  should deliver a viable MVP that provides user value.

  P1 = Must Have (MVP), P2 = Should Have, P3 = Nice to Have
-->

### US1: Periodic Logfile Compression (P1 - Must Have)

**As a** ztick operator running a long-lived scheduler with logfile persistence,
**I want** the logfile to be automatically compacted on a periodic interval,
**So that** disk usage stays bounded despite accumulated mutations (repeated SETs, REMOVEs, re-SETs on the same IDs).

**Why this priority**: Without compression, the logfile grows monotonically. A scheduler handling thousands of recurring jobs will accumulate megabytes of redundant entries per day. This is the core problem F009 exists to solve.

**Acceptance Scenarios:**
1. **Given** a running scheduler with `.logfile` backend and `compression_interval = 60`, **When** 60 seconds elapse since the last compression, **Then** the system renames the active logfile to `logfile.to_compress`, creates a fresh logfile for new writes, spawns a background compression thread, and produces a deduplicated `logfile.compressed` file.
2. **Given** a compression cycle completes successfully, **When** the scheduler continues operating, **Then** new mutations are appended to the fresh logfile without interruption and no data is lost.
3. **Given** the logfile contains 100 SET entries for the same job ID, **When** compression runs, **Then** the compressed output contains exactly 1 entry for that job ID (the latest mutation).
4. **Given** a job was SET then REMOVEd as its final state, **When** compression runs, **Then** the compressed output excludes that job entirely.

**Independent Test:** Start a scheduler with `compression_interval = 5`, send 50 SET mutations for the same job ID, wait 6 seconds, verify `logfile.compressed` exists and contains exactly 1 entry.

### US2: Memory Backend Skips Compression (P1 - Must Have)

**As a** ztick operator running with in-memory persistence,
**I want** the compression subsystem to be completely inactive,
**So that** no unnecessary threads are spawned and no file operations are attempted.

**Why this priority**: F008 FR-007 explicitly requires skipping compression for memory backends. Without this guard, the system would attempt file operations on a nonexistent logfile.

**Acceptance Scenarios:**
1. **Given** a running scheduler with `.memory` backend and `compression_interval = 10`, **When** 10 seconds elapse, **Then** no compression thread is spawned and no file operations occur.
2. **Given** a running scheduler with `.memory` backend, **When** the scheduler shuts down, **Then** no compression thread join or cleanup is performed.

**Independent Test:** Start a scheduler with `.memory` backend and `compression_interval = 1`, run for 3 seconds, verify no `logfile.to_compress` or `logfile.compressed` files exist and no background threads were spawned.

### US3: Graceful Shutdown During Compression (P2 - Should Have)

**As a** ztick operator,
**I want** in-flight compression to not block shutdown,
**So that** the scheduler stops promptly when signaled regardless of compression state.

**Why this priority**: Blocking shutdown on a potentially long compression operation degrades operational experience, but data safety on normal shutdown is already handled by the append-only logfile design.

**Acceptance Scenarios:**
1. **Given** a compression thread is running, **When** the scheduler receives a shutdown signal, **Then** the scheduler does not wait for compression to complete and exits within the normal shutdown timeout.
2. **Given** a compression was interrupted by shutdown, **When** the scheduler restarts, **Then** it loads from the original logfile (or compressed file if completed) without data loss, and any partial `.tmp` files are ignored or cleaned up on next compression cycle.

**Independent Test:** Start a scheduler with a large logfile and `compression_interval = 1`, trigger shutdown during compression, verify the process exits within 2 seconds and restarts cleanly.

### US4: Configurable Compression Interval (P3 - Nice to Have)

**As a** ztick operator,
**I want** to tune the compression interval via configuration,
**So that** I can balance disk usage against compression overhead for my workload.

**Why this priority**: A sensible default (3600 seconds) covers most deployments. Custom tuning is a convenience for high-mutation or resource-constrained environments.

**Acceptance Scenarios:**
1. **Given** a config file with `compression_interval = 120`, **When** the scheduler starts, **Then** compression triggers every 120 seconds.
2. **Given** no `compression_interval` key in the config file, **When** the scheduler starts with `.logfile` backend, **Then** compression triggers at the default interval of 3600 seconds (1 hour).
3. **Given** `compression_interval = 0` in the config file, **When** the scheduler starts, **Then** compression is disabled entirely.

**Independent Test:** Start a scheduler with `compression_interval = 3`, verify compression occurs at the 3-second mark; restart with no key, verify it triggers at the default interval.

### Edge Cases

<!--
  Boundary conditions, error scenarios, and unusual states.
  Each edge case should map to at least one user story.
-->

- What happens when the logfile is empty at compression time? The system produces an empty `.compressed` file and continues (US1).
- What happens when compression fails (e.g., disk full, permission denied)? The system logs the error, leaves the `.to_compress` file intact for retry on the next cycle, and continues normal operation (US1).
- What happens when a previous `.to_compress` file already exists at startup (leftover from interrupted compression)? The system compresses it first before starting the periodic timer (US1).
- What happens when two compression cycles overlap (previous one not finished when next interval triggers)? The system skips the trigger if a compression process is already running (US1).
- What happens when `compression_interval` is negative or exceeds u32 range? The config parser rejects it with `ConfigError.InvalidValue` (US4).

---

## Requirements

<!--
  Use "System MUST" for mandatory requirements.
  Use "Users MUST be able to" for user-facing capabilities.
  Each requirement must be independently testable.
-->

### Functional Requirements

- **FR-001**: System MUST spawn a background compression thread at each configured interval when the persistence backend is `.logfile`.
- **FR-002**: System MUST NOT spawn compression threads or perform any file operations related to compression when the persistence backend is `.memory`.
- **FR-003**: System MUST atomically rename the active logfile to `logfile.to_compress` and create a fresh logfile before starting compression, ensuring no write gap for incoming mutations.
- **FR-004**: System MUST skip a compression cycle if a previous compression process is still running, as reported by `Process.status() == .running`.
- **FR-005**: System MUST NOT block shutdown waiting for an in-flight compression thread to complete.
- **FR-006**: System MUST use the default compression interval of 3600 seconds when no `compression_interval` key is present in the configuration.
- **FR-007**: System MUST disable compression entirely when `compression_interval` is set to 0.
- **FR-008**: System MUST log a warning when a compression cycle fails and leave the `.to_compress` file intact for the next cycle.
- **FR-009**: System MUST compress any leftover `.to_compress` file found at startup before starting the periodic timer.
- **FR-010**: Users MUST be able to configure the compression interval via the `compression_interval` key in the `[database]` configuration section.

### Non-Functional Requirements

- **NFR-001**: Compression MUST NOT block or delay the scheduler tick loop; all compression work happens in a background thread via the existing `Process` executor.
- **NFR-002**: The rename-and-create operation for logfile rotation (FR-003) MUST complete in under 1ms to minimize the window where incoming appends could fail.
- **NFR-003**: Compression scheduling MUST add zero overhead to the tick loop when the backend is `.memory` — no timer checks, no status polls, no allocations.
- **NFR-004**: The compression thread MUST release all allocated memory upon completion, whether successful or failed, consistent with existing `Process.deinit()` behavior.

---

## Success Criteria

<!--
  Success criteria MUST be:
  - Measurable: include specific metrics (time, percentage, count)
  - Technology-agnostic: no mention of frameworks, languages, databases
  - User-focused: describe outcomes from user/business perspective
  - Verifiable: can be tested without knowing implementation details
-->

- **SC-001**: A scheduler running with logfile persistence for 24 hours with 10,000 mutations on 100 recurring job IDs produces a logfile under 50KB after compression, compared to unbounded growth without compression.
- **SC-002**: Compression cycles complete without any observable interruption to mutation processing — zero dropped SET/REMOVE commands during compression.
- **SC-003**: Scheduler shutdown completes within 2 seconds regardless of whether a compression cycle is in progress.
- **SC-004**: Memory backend deployments show zero file system activity related to compression over any runtime duration.
- **SC-005**: All existing 237+ tests continue to pass with zero modifications.

---

## Key Entities

<!--
  Include only if the feature involves data modeling.
  Describe entities at the domain level, not database schema.
-->

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| CompressionScheduler | Manages periodic triggering of compression cycles based on elapsed time | interval (seconds), last_run_timestamp (nanoseconds), active_process (optional reference to running Process) |
| Process | Existing background task executor that runs compression in a separate thread | thread handle, mutex-protected result, status (running/success/failure) |
| Filenames | Existing naming convention for compression file stages | source (.to_compress), staging (.compressed.tmp), destination (.compressed) |

---

## Assumptions

<!--
  Document reasonable defaults and assumptions made during spec generation.
  These should be validated during the clarification step.
-->

- The existing `compress()` function and `Process` executor require no modifications; they are correct and sufficient as-is.
- The tick loop provides nanosecond timestamps suitable for tracking elapsed time since last compression.
- Logfile rename (`logfile` → `logfile.to_compress`) is atomic on the target filesystem (POSIX guarantee for same-filesystem rename).
- After renaming the active logfile, creating a new empty logfile for continued writes is sufficient — the `LogfilePersistence` backend opens the file on each append, so it will naturally create the new file.
- A 3600-second default interval is appropriate for most workloads; operators with high mutation rates can lower it.
- Interrupted compression leaving a `.to_compress` file is safe because the scheduler's load path can handle both the original logfile and `.to_compress`/`.compressed` files.

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: medium
- **Estimation**: M

## Dependencies

- **Blocked by**: F008 (in-memory persistence backend — provides PersistenceBackend union for conditional guard)
- **Unblocks**: none

## Clarifications

<!--
  Populated during the clarify step with resolved ambiguities.
  Each session is dated. Format:
  ### Session YYYY-MM-DD
  - Q: [question] -> A: [answer]
-->

_Section populated during clarify step with resolved ambiguities._

## Notes

- The `compress()` function, `Process` executor, and all 7 associated tests already exist in `src/infrastructure/persistence/background.zig` — this feature is purely about wiring and scheduling, not algorithm implementation.
- The current import `_ = infrastructure_persistence_background` in `main.zig` suppresses the unused-import warning; this feature replaces that suppression with actual usage.
- File preparation (renaming active logfile to `.to_compress`) is new work not covered by the existing `compress()` function, which assumes `.to_compress` already exists.
- The `LogfilePersistence.append()` method opens the logfile by path on each call (`openFile(.write_only)` with `createFile` fallback), so rotating the file via rename is transparent to the append path — the next append will create a fresh file automatically.
- F008 FR-007 ("System MUST skip background compression when the persistence backend is memory") is currently vacuously true because compression never runs. This feature makes it substantively true via the `.logfile` guard in FR-001/FR-002.
