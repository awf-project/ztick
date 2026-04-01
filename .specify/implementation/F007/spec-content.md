# F007: Logfile Dump Command

## Scope

<!--
  Define what this feature covers and what it explicitly does NOT cover.
  This prevents scope creep and sets clear boundaries for implementation.
-->

### In Scope

- CLI `dump` subcommand that reads and decodes the binary persistence logfile to stdout
- Two output formats: human-readable text (default) and NDJSON (one JSON object per line)
- `--compact` flag to deduplicate entries and strip removals, showing effective state only
- `--follow` flag for live tail mode that watches for newly appended entries
- Graceful handling of partial writes, locked logfiles, and decode errors

### Out of Scope

- Remote dump over TCP (connecting to a running ztick instance to fetch state)
- GUI or TUI viewer for logfile contents
- Logfile repair or rewrite capabilities
- Filtering by entry type, identifier pattern, or time range within the dump command

### Deferred

<!--
  Track work that was considered but intentionally postponed.
  Each item must have a rationale to prevent scope amnesia.
-->

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| Entry filtering (`--type`, `--pattern`, `--since`) | Keep initial CLI surface minimal; `jq` covers JSON filtering | future |
| Binary-to-binary compaction via CLI | Compaction already runs in-process via `background.zig`; CLI compaction adds write semantics | future |
| Remote state dump over protocol | Requires new protocol command; dump should work without a running server | future |

---

## User Stories

<!--
  User stories are PRIORITIZED vertical slices ordered by importance.
  Each story must be INDEPENDENTLY TESTABLE - implementing just ONE
  should deliver a viable MVP that provides user value.

  P1 = Must Have (MVP), P2 = Should Have, P3 = Nice to Have
-->

### US1: Inspect Logfile Contents as Text (P1 - Must Have)

**As an** operator,
**I want** to run `ztick dump <logfile_path>` and see every persisted entry printed as human-readable text,
**So that** I can inspect and debug the persistence state without understanding the binary format.

**Why this priority**: This is the core value proposition — making the opaque binary logfile readable. Without this, operators have no offline inspection tool. Every other story builds on this capability.

**Acceptance Scenarios:**
1. **Given** a logfile containing SET, RULE SET, REMOVE, and REMOVERULE entries, **When** I run `ztick dump log.bin`, **Then** each entry is printed to stdout as one line in text format matching the protocol command syntax, and the process exits with code 0.
2. **Given** a logfile that does not exist at the specified path, **When** I run `ztick dump missing.bin`, **Then** an error message is printed to stderr and the process exits with code 1.
3. **Given** an empty logfile (0 bytes), **When** I run `ztick dump empty.bin`, **Then** no output is printed to stdout and the process exits with code 0.

**Independent Test:** Create a logfile with known entries using the existing encoder, run `ztick dump` on it, and compare stdout line-by-line against expected text output.

### US2: Export Logfile as NDJSON (P1 - Must Have)

**As an** operator,
**I want** to run `ztick dump <logfile_path> --format json` and get one JSON object per entry on stdout,
**So that** I can pipe the output to `jq` for filtering, transformation, and integration with monitoring tools.

**Why this priority**: JSON output enables machine consumption and composability with standard Unix tooling. This is essential for audit trail use cases and automated analysis, making it a core requirement alongside text output.

**Acceptance Scenarios:**
1. **Given** a logfile with a SET entry, **When** I run `ztick dump log.bin --format json`, **Then** a single JSON object is printed with keys `type`, `identifier`, `execution`, and `status`, and the output is valid NDJSON.
2. **Given** a logfile with a RULE SET entry using shell runner, **When** I run `ztick dump log.bin --format json`, **Then** the JSON object includes a nested `runner` object with `type` and `command` fields.
3. **Given** a logfile with multiple entries, **When** I run `ztick dump log.bin --format json | jq 'select(.type=="set")'`, **Then** only SET entries are printed, confirming valid NDJSON streaming.

**Independent Test:** Create a logfile with all four entry types, run with `--format json`, parse each line as JSON, and validate schema and field values.

### US3: View Effective State with Compact Mode (P2 - Should Have)

**As an** operator,
**I want** to run `ztick dump <logfile_path> --compact` to see only the final effective state per identifier,
**So that** I can quickly understand what jobs and rules are currently active without reading through the full mutation history.

**Why this priority**: Compact mode adds significant diagnostic value by answering "what is the current state?" rather than "what happened?" — but the full history (US1/US2) is more fundamental and must work first.

**Acceptance Scenarios:**
1. **Given** a logfile where job `a` is SET twice with different timestamps, **When** I run `ztick dump log.bin --compact`, **Then** only the latest SET for job `a` is printed.
2. **Given** a logfile where job `b` is SET then REMOVEd, **When** I run `ztick dump log.bin --compact`, **Then** job `b` does not appear in the output at all.
3. **Given** `--compact` combined with `--format json`, **When** I run `ztick dump log.bin --compact --format json`, **Then** the compacted entries are printed as NDJSON.

**Independent Test:** Create a logfile with overlapping SET/REMOVE sequences, run with `--compact`, and verify the output matches the expected deduplicated state.

### US4: Live Tail of Logfile Changes (P3 - Nice to Have)

**As an** operator,
**I want** to run `ztick dump <logfile_path> --follow` to see new entries as they are appended by a running ztick instance,
**So that** I can monitor mutations in real time during incident response or debugging.

**Why this priority**: Follow mode is powerful for live debugging but requires platform-specific file watching (inotify/kqueue/poll fallback), adding implementation complexity. The static dump (US1/US2) covers most use cases.

**Acceptance Scenarios:**
1. **Given** a logfile and a running ztick instance appending entries, **When** I run `ztick dump log.bin --follow`, **Then** existing entries are printed first, followed by new entries as they are appended.
2. **Given** `--follow` is active, **When** I send SIGINT, **Then** the process exits cleanly with code 0.
3. **Given** `--follow` combined with `--format json`, **When** new entries are appended, **Then** each new entry is printed as a single JSON line suitable for streaming to `jq`.

**Independent Test:** Start `ztick dump --follow` in a subprocess, append known entries to the logfile, read subprocess stdout, and verify the new entries appear within a bounded time window.

### Edge Cases

<!--
  Boundary conditions, error scenarios, and unusual states.
  Each edge case should map to at least one user story.
-->

- What happens when the logfile ends with a partial frame (truncated write)? → Print all complete entries, emit a warning to stderr, exit 0 (US1).
- What happens when a frame contains an unrecognized entry type byte? → Print a warning to stderr with the byte offset, skip the frame, continue (US1).
- What happens when the logfile is being written to concurrently by ztick? → Open read-only; partial trailing frame is treated as truncated (US1, US4).
- What happens when `--follow` is used on a file that is not being appended to? → Block indefinitely until SIGINT, printing nothing after the initial dump (US4).
- What happens when `--compact` is used on a logfile with only REMOVE entries and no corresponding SETs? → No output, as there is no effective state (US3).
- What happens when the logfile path points to a directory or device? → Print error to stderr, exit 1 (US1).

---

## Requirements

<!--
  Use "System MUST" for mandatory requirements.
  Use "Users MUST be able to" for user-facing capabilities.
  Each requirement must be independently testable.
-->

### Functional Requirements

- **FR-001**: System MUST parse the `dump` subcommand from CLI arguments, distinguishing it from the default server mode based on the first positional argument.
- **FR-002**: System MUST accept a mandatory positional argument `<logfile_path>` specifying the path to the binary logfile.
- **FR-003**: System MUST accept an optional `--format` flag with values `text` (default) or `json`.
- **FR-004**: System MUST read the logfile, parse length-prefixed frames, decode each entry, and write the formatted output to stdout — one entry per line.
- **FR-005**: System MUST format text output matching protocol command syntax: `SET <id> <timestamp_ns> <status>`, `RULE SET <id> <pattern> <runner_type> [args...]`, `REMOVE <id>`, `REMOVERULE <id>`.
- **FR-006**: System MUST format JSON output as NDJSON with fields: `type` (set, rule_set, remove, remove_rule), `identifier`, and type-specific fields (`execution`, `status`, `pattern`, `runner`).
- **FR-007**: System MUST accept an optional `--compact` flag that deduplicates entries by identifier and omits entries whose final mutation is a removal.
- **FR-008**: System MUST accept an optional `--follow` flag that, after printing existing entries, watches the logfile for new appended data and prints new entries as they appear.
- **FR-009**: System MUST exit with code 0 on success and code 1 on fatal errors (file not found, permission denied), printing the error message to stderr.
- **FR-010**: System MUST handle partial trailing frames gracefully by printing a warning to stderr and continuing with all successfully parsed entries.
- **FR-011**: System MUST open the logfile in read-only mode, allowing concurrent use while ztick is running.

### Non-Functional Requirements

- **NFR-001**: Dump MUST stream entries to stdout incrementally — memory usage SHALL NOT scale with logfile size (excluding `--compact` mode which requires full read).
- **NFR-002**: No secrets, file contents, or shell command arguments SHALL appear in error messages written to stderr — only entry counts, byte offsets, and structural errors.
- **NFR-003**: Follow mode MUST respond to SIGINT/SIGTERM within 1 second and exit cleanly.
- **NFR-004**: Zero external dependencies — implementation MUST use only the Zig standard library, consistent with the existing build constraint.

---

## Success Criteria

<!--
  Success criteria MUST be:
  - Measurable: include specific metrics (time, percentage, count)
  - Technology-agnostic: no mention of frameworks, languages, databases
  - User-focused: describe outcomes from user/business perspective
  - Verifiable: can be tested without knowing implementation details
-->

- **SC-001**: Operators can inspect the full contents of any valid logfile in under 5 seconds for files up to 100MB.
- **SC-002**: JSON output is valid NDJSON — every line parses as a standalone JSON object with 100% success rate across all entry types.
- **SC-003**: Compact mode output matches the effective state that the scheduler would reconstruct on startup for 100% of test logfiles.
- **SC-004**: Follow mode detects and prints newly appended entries within 2 seconds of the write completing.
- **SC-005**: All four entry types (SET, RULE SET, REMOVE, REMOVERULE) round-trip correctly through encode → logfile → dump in both text and JSON formats.

---

## Key Entities

<!--
  Include only if the feature involves data modeling.
  Describe entities at the domain level, not database schema.
-->

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| Entry | A single persisted mutation in the logfile | type (set, rule_set, remove, remove_rule), identifier, type-specific payload |
| Frame | A length-prefixed binary container holding one encoded Entry | length (4-byte big-endian), payload bytes |
| DumpOptions | Configuration for the dump command parsed from CLI flags | logfile_path, format (text/json), compact (bool), follow (bool) |

---

## Assumptions

<!--
  Document reasonable defaults and assumptions made during spec generation.
  These should be validated during the clarification step.
-->

- The existing `logfile.parse()` and `encoder.decode()` functions can be reused or adapted for streaming (frame-by-frame) decoding without requiring a full refactor.
- Logfiles written by the current ztick version use a stable binary format — no version negotiation is needed for the dump command.
- Follow mode can use a polling fallback (periodic stat check) as a minimum viable implementation; inotify/kqueue optimization is acceptable but not required for initial delivery.
- The `--compact` flag requires loading all entries into memory for deduplication, which is acceptable given that compacted logfiles are bounded by the number of unique identifiers.
- The subcommand pattern (`ztick dump` vs `ztick` for server) is the first subcommand and does not require a full subcommand framework — simple first-argument dispatch is sufficient.

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: high
- **Estimation**: L

## Dependencies

- **Blocked by**: none
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

- This doubles as the audit trail solution — `ztick dump --format json` provides a complete, machine-readable history of all mutations without requiring a separate audit feature.
- Pairs with F005 (startup logging) — between journald logs for runtime events and `ztick dump` for persisted state, operators have full observability.
- The `--compact` deduplication logic should reuse the same approach as `background.zig` compressor to avoid behavioral divergence.
- NDJSON chosen over JSON array to enable streaming output and compatibility with `jq` line-by-line filtering.
- Follow mode with `--format json` enables live monitoring pipelines: `ztick dump log.bin --format json --follow | jq 'select(.type=="set")'`.
