# F002: QUERY Command for Pattern-Based Job Lookup

## Scope

### In Scope

- `query` variant added to `Instruction` tagged union
- Prefix-based pattern matching on `JobStorage` job identifiers
- `QueryHandler` dispatch for `query` instruction producing multi-line responses
- `QUERY <pattern>` parsing in TCP server's `build_instruction()`
- Multi-line response format: one line per matching job, terminated by `OK`
- Unit and functional tests covering match, no-match, and multiple-match cases

### Out of Scope

- Glob or regex pattern matching (only prefix matching)
- Pagination or result-set limiting
- QUERY over rule storage (only job storage)
- Persistence of query operations (read-only command)

### Deferred

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| Glob/regex pattern semantics | No stdlib support; prefix matching is consistent with `RuleStorage.pair()` | future |
| Result pagination / LIMIT clause | No demonstrated need at current scale; adds protocol complexity | future |
| Query by status filter (`QUERY <pattern> <status>`) | Useful but compounds scope; status filtering exists via `get_by_status()` already | future |
| Sorted result ordering guarantee | Useful for deterministic output but requires defining sort key contract | future |

---

## User Stories

### US1: Query Jobs by Identifier Prefix (P1 - Must Have)

**As a** scheduler operator,
**I want** to send `QUERY <prefix>` over TCP and receive all jobs whose identifier starts with that prefix,
**So that** I can inspect scheduled job state without grepping the logfile or restarting the server.

**Why this priority**: This is the core capability — without pattern-based lookup, there is no way to introspect job state at runtime. Every other story depends on this working.

**Acceptance Scenarios:**
1. **Given** three jobs exist with IDs `backup.daily`, `backup.weekly`, `deploy.prod`, **When** I send `QUERY backup.`, **Then** the response contains exactly two lines (one per backup job) followed by a terminal `OK` line.
2. **Given** a job `cron.cleanup` exists with status `executed` and execution timestamp `1711670400000000000`, **When** I send `QUERY cron.`, **Then** the response line contains the job ID, status, and execution timestamp in the format `<request_id> cron.cleanup executed 1711670400000000000`.
3. **Given** no jobs exist, **When** I send `QUERY anything`, **Then** the response is a single `<request_id> OK` line.

**Independent Test:** Start the server, SET three jobs with distinct prefixes via TCP, send QUERY with a known prefix, assert the returned lines match expected job IDs and statuses.

### US2: Empty Pattern Returns All Jobs (P2 - Should Have)

**As a** scheduler operator,
**I want** `QUERY ""` (empty pattern) to return all jobs,
**So that** I can enumerate the full job list without knowing specific prefixes.

**Why this priority**: Completes the query surface — prefix match with empty string is a natural "list all" operation. Not strictly required for targeted lookups but expected by users.

**Acceptance Scenarios:**
1. **Given** five jobs exist with various prefixes, **When** I send `QUERY ""`, **Then** all five jobs appear in the response, each on its own line, followed by `OK`.

**Independent Test:** SET five jobs, send `QUERY ""`, count response lines (expect 5 data lines + 1 OK line).

### US3: QUERY with No Matches Returns Clean OK (P3 - Nice to Have)

**As a** scheduler operator,
**I want** a QUERY that matches zero jobs to return only `<request_id> OK` (not an error),
**So that** I can distinguish "no results" from "command failed" in scripts and automation.

**Why this priority**: Important for correctness but the simplest case to implement — the empty result set is a subset of the general case in US1.

**Acceptance Scenarios:**
1. **Given** jobs exist with prefix `backup.`, **When** I send `QUERY deploy.`, **Then** the response is `<request_id> OK` with no data lines.

**Independent Test:** SET jobs with one prefix, QUERY a non-matching prefix, assert response is exactly one OK line.

### Edge Cases

- What happens when QUERY is sent with no pattern argument? Response MUST be `<request_id> ERROR` (malformed command).
- What happens when the pattern contains quoted strings with spaces (e.g., `QUERY "my prefix"`)? The existing quoted-string parser applies; the pattern is the unquoted content.
- What happens when hundreds of jobs match? All are returned — no implicit limit. Memory is bounded by the job set size, which is already fully resident.
- What is the behavior when a QUERY arrives concurrently with a SET modifying the same job? The query reads a consistent snapshot from `JobStorage`'s mutex-guarded hashmap — it sees either the pre-SET or post-SET state, never a partial update.

---

## Requirements

### Functional Requirements

- **FR-001**: System MUST parse `<request_id> QUERY <pattern>
` as a valid instruction, where `<pattern>` is a required argument.
- **FR-002**: System MUST return one line per matching job in the format `<request_id> <job_id> <status> <execution_ns>
`, followed by `<request_id> OK
`.
- **FR-003**: System MUST match jobs whose identifier starts with the given pattern (prefix match).
- **FR-004**: System MUST return `<request_id> OK
` with zero data lines when no jobs match.
- **FR-005**: System MUST return `<request_id> ERROR
` when QUERY is sent with missing pattern argument.
- **FR-006**: System MUST NOT write any persistence entry for QUERY operations (read-only).
- **FR-007**: System MUST handle the `query` variant in `free_instruction_strings()` to prevent memory leaks or compilation errors.

### Non-Functional Requirements

- **NFR-001**: QUERY response time MUST scale linearly with the number of stored jobs (single pass over hashmap).
- **NFR-002**: QUERY MUST NOT block SET or RULE SET operations beyond the duration of the hashmap lock acquisition.
- **NFR-003**: Result set memory MUST be freed after response is written to the TCP connection.

---

## Success Criteria

- **SC-001**: `echo '<id> QUERY backup.' | nc localhost 5678` returns all jobs with `backup.` prefix within 10ms for a store of 1000 jobs.
- **SC-002**: All existing tests continue to pass — zero regressions from adding the `query` variant to the `Instruction` union.
- **SC-003**: Unit tests cover match, no-match, and multi-match scenarios with 100% branch coverage of the new code paths.
- **SC-004**: Functional test demonstrates end-to-end SET → QUERY → verify cycle over a live TCP connection.

---

## Key Entities

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| Instruction (query variant) | Represents a parsed QUERY command from the protocol | `pattern: []const u8` |
| Job | Existing domain entity returned in query results | `id: []const u8`, `status: Status`, `execution_ns: i64` |
| Response | Extended to carry multi-line body for list-style results | `body: ?[][]const u8` or equivalent multi-line payload |

---

## Assumptions

- Prefix matching is the correct pattern semantics — consistent with `RuleStorage.pair()` behavior and simplest to implement without external dependencies.
- The GET command (F001) will be implemented first, establishing the `Response` extension pattern for data-carrying responses. QUERY builds on that same extension.
- Job result ordering is unspecified in v1 — iteration order of the hashmap is acceptable. Deterministic sort is deferred.
- The result set fits in memory — bounded by the total job count, which is already fully resident in `JobStorage`.

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: high
- **Estimation**: M

## Dependencies

- **Blocked by**: F001 (GET command — shares Response extension design)
- **Unblocks**: none

## Clarifications

_Section populated during clarify step with resolved ambiguities._

## Notes

- The `append_to_logfile()` switch on instruction type needs a `query` arm that explicitly does nothing (no persistence for reads).
- `RuleStorage.pair()` demonstrates the prefix matching pattern via `rule.supports(job)` — reuse the same semantics for consistency.
- Multi-line response format establishes a protocol precedent. Future list-style commands (e.g., LIST RULES) should follow the same `<id> <data>
 ... <id> OK
` convention.
- Files affected: `src/domain/instruction.zig`, `src/domain/query.zig`, `src/application/job_storage.zig`, `src/application/query_handler.zig`, `src/infrastructure/tcp_server.zig`, `src/functional_tests.zig`.
