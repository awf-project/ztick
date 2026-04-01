# F003: REMOVE and REMOVERULE Commands

## Scope

### In Scope

- `REMOVE <job_id>` command to delete scheduled jobs via TCP protocol
- `REMOVERULE <rule_id>` command to delete execution rules via TCP protocol
- Persistence of removal operations to the append-only logfile
- Correct interaction with background compression (removed IDs excluded from compacted output)
- Unit and functional tests for both commands

### Out of Scope

- Cascade deletion (REMOVE does not touch rules; REMOVERULE does not cancel pending jobs)
- Bulk removal or wildcard patterns (e.g., `REMOVE *`)
- HTTP transport for removal commands (deferred to HTTP controller feature)

### Deferred

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| Cascade delete (remove rule → cancel pending jobs) | Adds semantic complexity; simple independent operations are more predictable | future |
| Bulk/wildcard removal | No protocol syntax defined; single-ID removal covers primary use case | future |
| REMOVE confirmation body (returning deleted entity data) | Current protocol response is OK/ERROR only; adding response bodies is a broader protocol change | future |

---

## User Stories

### US1: Remove a Scheduled Job (P1 - Must Have)

**As a** scheduler operator,
**I want** to remove a previously scheduled job by ID,
**So that** the job does not execute and the removal survives server restarts.

**Why this priority**: Without REMOVE, the only way to prevent a scheduled job from firing is to stop the server. This is the core deletion primitive for job lifecycle management.

**Acceptance Scenarios:**
1. **Given** a job "backup-daily" was scheduled via SET, **When** I send `REMOVE backup-daily`, **Then** the server responds with `OK` and the job no longer appears in storage.
2. **Given** no job "nonexistent" exists, **When** I send `REMOVE nonexistent`, **Then** the server responds with `ERROR`.
3. **Given** a job "cleanup" was scheduled and then removed, **When** the server restarts and replays the logfile, **Then** "cleanup" is not present in storage.
4. **Given** a job "task-1" is queued in the to_execute list, **When** I send `REMOVE task-1`, **Then** the job is removed from both the jobs hashmap and the to_execute list.

**Independent Test:** Schedule a job via SET, send REMOVE, then send GET for the same ID and confirm the response indicates the job does not exist.

### US2: Remove an Execution Rule (P1 - Must Have)

**As a** scheduler operator,
**I want** to remove an execution rule by ID,
**So that** future jobs matching that rule are no longer dispatched to the associated runner.

**Why this priority**: Rules bind job patterns to runners. Without REMOVERULE, misconfigured or obsolete rules cannot be cleaned up, leading to unintended execution.

**Acceptance Scenarios:**
1. **Given** a rule "notify-slack" was created via RULE SET, **When** I send `REMOVERULE notify-slack`, **Then** the server responds with `OK` and the rule is removed from storage.
2. **Given** no rule "ghost-rule" exists, **When** I send `REMOVERULE ghost-rule`, **Then** the server responds with `ERROR`.
3. **Given** a rule was created and then removed, **When** the server restarts, **Then** the rule is not present in storage after logfile replay.

**Independent Test:** Create a rule via RULE SET, send REMOVERULE, then verify the rule no longer matches any scheduled job execution.

### US3: Removal Survives Compression (P2 - Should Have)

**As a** scheduler operator,
**I want** removal entries to be correctly handled during background log compression,
**So that** compressed logfiles do not resurrect deleted jobs or rules.

**Why this priority**: Compression is a background optimization. If removals are lost during compaction, deleted entries silently reappear after restart — a data integrity issue, but only manifests after compression runs.

**Acceptance Scenarios:**
1. **Given** a job was SET then REMOVEd, **When** the background compressor runs, **Then** the compressed logfile contains no entry for that job ID.
2. **Given** a rule was created and then removed, **When** the compressor builds the deduplicated output, **Then** the rule ID is excluded entirely.

**Independent Test:** Write a SET entry followed by a REMOVE entry to a logfile, run compression, decode the compressed file, and confirm the ID is absent.

### Edge Cases

- What happens when REMOVE targets a job ID that was already removed? Server responds `ERROR` (idempotent from the client perspective — the job does not exist).
- What happens when REMOVE is sent with no argument? Parser rejects with `ERROR` due to insufficient arguments.
- What happens when REMOVE and SET arrive concurrently for the same ID? The append-only log records both; replay order determines final state. Last-write-wins semantics.
- What happens when a job in the to_execute queue is removed between tick and execution? The processor should handle missing jobs gracefully (already required by design — jobs may expire).

---

## Requirements

### Functional Requirements

- **FR-001**: System MUST parse `REMOVE <job_id>` commands from the TCP protocol and route them to the query handler.
- **FR-002**: System MUST parse `REMOVERULE <rule_id>` commands from the TCP protocol and route them to the query handler.
- **FR-003**: System MUST delete the identified job from `JobStorage` when processing a `remove` instruction, including removal from the `to_execute` list.
- **FR-004**: System MUST delete the identified rule from `RuleStorage` when processing a `remove_rule` instruction.
- **FR-005**: System MUST respond with `OK` when the target entry existed and was removed, and `ERROR` when the target entry was not found.
- **FR-006**: System MUST persist REMOVE and REMOVERULE operations to the append-only logfile before confirming `OK` to the client.
- **FR-007**: System MUST replay removal entries during logfile loading so that removed entries are absent from post-load storage state.
- **FR-008**: System MUST exclude removed IDs from compressed logfile output during background compaction.
- **FR-009**: System MUST respect `fsync_on_persist` configuration for removal entries, matching SET behavior.

### Non-Functional Requirements

- **NFR-001**: REMOVE and REMOVERULE command processing latency MUST be comparable to SET (sub-millisecond excluding fsync).
- **NFR-002**: Removal persistence entries MUST use the existing length-prefixed framing format with no new framing scheme.
- **NFR-003**: No new allocations beyond the identifier string copy for removal instructions; memory usage MUST not grow with removal count.

---

## Success Criteria

- **SC-001**: `REMOVE <id>` for an existing job returns `OK` and the job is no longer retrievable via GET.
- **SC-002**: `REMOVERULE <id>` for an existing rule returns `OK` and the rule no longer triggers execution.
- **SC-003**: After server restart, previously removed jobs and rules remain absent from storage.
- **SC-004**: Background compression of a logfile containing SET+REMOVE pairs for the same ID produces output with zero entries for that ID.
- **SC-005**: All new code paths covered by unit tests (delete existing, delete missing) and functional tests (SET→REMOVE→GET round-trip).

---

## Key Entities

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| Instruction | Tagged union representing a parsed protocol command | New variants: `remove { identifier }`, `remove_rule { identifier }` |
| JobStorage | HashMap-backed store for scheduled jobs | New method: `delete(identifier) -> bool` |
| RuleStorage | HashMap-backed store for execution rules | Existing method: `delete(identifier) -> bool` |
| PersistenceEntry | Encoded logfile record | New type bytes for job removal and rule removal entries |

---

## Assumptions

- `RuleStorage.delete()` already exists and returns `bool` — no new method needed on the rule storage side.
- The existing `write_response()` function handles `OK`/`ERROR` without modification — no response body is needed for removal commands.
- The `to_execute` list in `JobStorage` is a linear structure that can be scanned for removal without performance concern at current scale.
- Removal entries in the persistence format will use new type discriminant bytes (e.g., `2` for job removal, `3` for rule removal) with a single length-prefixed identifier field.

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: high
- **Estimation**: M

## Dependencies

- **Blocked by**: none
- **Unblocks**: none

## Clarifications

_Section populated during clarify step with resolved ambiguities._

## Notes

- The `Instruction` tagged union extension is shared with GET and QUERY commands. Implementing REMOVE/REMOVERULE alongside those commands reduces churn in `build_instruction()`, `is_borrowed_by_instruction()`, and `free_instruction_strings()`.
- Persistence encoding for removal is minimal: type byte + length-prefixed identifier. No timestamp, status, or runner data needed.
- The compressor in `persistence/background.zig` builds a `last_index` map keyed by ID. When the last entry for an ID is a removal, the ID must be excluded from compressed output entirely rather than written as a removal entry.
