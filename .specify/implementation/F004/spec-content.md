# F004: Add LISTRULES Command

## Scope

<!--
  Define what this feature covers and what it explicitly does NOT cover.
  This prevents scope creep and sets clear boundaries for implementation.
-->

### In Scope

- Parse `LISTRULES` command from TCP protocol and map to a new instruction variant
- Iterate rule storage and return all rules in a multi-line response (same framing as QUERY)
- Read-only command — no persistence writes
- Unit and functional tests for parsing, handling, and response formatting

### Out of Scope

- Filtering or pattern-matching rules (e.g., `LISTRULES backup.*`) — this is a full dump only
- Rule ordering guarantees — hash map iteration order is undefined
- Paginated or streamed responses for large rule sets
- REMOVE and REMOVERULE command implementations

### Deferred

<!--
  Track work that was considered but intentionally postponed.
  Each item must have a rationale to prevent scope amnesia.
-->

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| Filtered rule listing (`LISTRULES <pattern>`) | Keep initial command simple; no user demand yet | future |
| REMOVE command | Separate feature scope | F005 or future |
| REMOVERULE command | Separate feature scope | F006 or future |

---

## User Stories

<!--
  User stories are PRIORITIZED vertical slices ordered by importance.
  Each story must be INDEPENDENTLY TESTABLE - implementing just ONE
  should deliver a viable MVP that provides user value.

  P1 = Must Have (MVP), P2 = Should Have, P3 = Nice to Have
-->

### US1: List All Configured Rules (P1 - Must Have)

**As a** ztick operator,
**I want** to send a `LISTRULES` command over the TCP protocol,
**So that** I can inspect which rules are currently loaded without restarting the server or reading the logfile.

**Why this priority**: This is the entire feature — without it, operators have no runtime visibility into rule configuration. It unblocks debugging, operational verification, and tooling built on top of the protocol.

**Acceptance Scenarios:**
1. **Given** two rules are loaded (`rule.backup backup.* shell /usr/bin/backup.sh` and `rule.notify notify.* shell /usr/bin/notify.sh`), **When** a client sends `r1 LISTRULES
`, **Then** the server responds with one line per rule prefixed by `r1`, each containing rule ID, pattern, runner type, and runner args, followed by `r1 OK
`.
2. **Given** no rules are loaded, **When** a client sends `r1 LISTRULES
`, **Then** the server responds with only `r1 OK
` (no rule lines).

**Independent Test:** Connect via TCP, send `RULE SET` for two rules, then send `LISTRULES` and verify both rules appear in the response followed by `OK`.

### US2: Multi-Line Response Consistency (P2 - Should Have)

**As a** tool author building on the ztick protocol,
**I want** `LISTRULES` to use the same multi-line response format as `QUERY`,
**So that** I can reuse existing response parsers without special-casing.

**Why this priority**: Protocol consistency reduces integration effort and prevents bugs in client implementations. Not strictly required for MVP but important for adoption.

**Acceptance Scenarios:**
1. **Given** rules are loaded, **When** a client sends `r1 LISTRULES
`, **Then** each rule line is prefixed with the request ID `r1` and the final line is `r1 OK
`, matching the QUERY response format.
2. **Given** a rule with a shell runner, **When** `LISTRULES` returns it, **Then** the line format is `<request_id> <rule_id> <pattern> <runner_type> <runner_args>
`.

**Independent Test:** Send `LISTRULES`, parse the response using the same multi-line parser used for QUERY, and verify it succeeds without modification.

### US3: AMQP Runner Rules in LISTRULES Output (P3 - Nice to Have)

**As a** ztick operator using AMQP runners,
**I want** `LISTRULES` to correctly display AMQP rule details (DSN, exchange, routing key),
**So that** I can verify AMQP-based rules are configured correctly.

**Why this priority**: AMQP runners are a secondary runner type. Shell runners cover the primary use case; AMQP display is additive.

**Acceptance Scenarios:**
1. **Given** a rule with an AMQP runner (`rule.publish events.* amqp amqp://localhost exchange_name routing.key`), **When** `LISTRULES` is sent, **Then** the response line includes all three AMQP fields: DSN, exchange, and routing key.

**Independent Test:** Load one AMQP rule via `RULE SET`, send `LISTRULES`, and verify the response line contains all AMQP runner fields.

### Edge Cases

<!--
  Boundary conditions, error scenarios, and unusual states.
  Each edge case should map to at least one user story.
-->

- What happens when no rules exist? The server responds with only `<request_id> OK
` (US1, scenario 2).
- What happens when `LISTRULES` is sent with unexpected trailing arguments (e.g., `r1 LISTRULES foo`)? The server ignores extra arguments and returns the full rule list (consistent with protocol tolerance).
- What is the behavior when rules are added concurrently while a `LISTRULES` response is being written? The scheduler processes requests sequentially on the database thread, so no race condition is possible — the response reflects a consistent snapshot.

---

## Requirements

<!--
  Use "System MUST" for mandatory requirements.
  Use "Users MUST be able to" for user-facing capabilities.
  Each requirement must be independently testable.
-->

### Functional Requirements

- **FR-001**: System MUST parse `<request_id> LISTRULES
` as a valid protocol command and map it to a `list_rules` instruction variant.
- **FR-002**: System MUST respond with one line per loaded rule in the format `<request_id> <rule_id> <pattern> <runner_type> <runner_args...>
`, followed by a terminal `<request_id> OK
`.
- **FR-003**: System MUST respond with only `<request_id> OK
` when no rules are loaded.
- **FR-004**: System MUST NOT write any persistence entry for `LISTRULES` commands (read-only).
- **FR-005**: System MUST format shell runner rules as `<rule_id> <pattern> shell <command>` and AMQP runner rules as `<rule_id> <pattern> amqp <dsn> <exchange> <routing_key>`.

### Non-Functional Requirements

- **NFR-001**: LISTRULES response time MUST be under 10ms for up to 1000 rules, since it is a linear scan of an in-memory hash map.
- **NFR-002**: LISTRULES MUST NOT allocate memory proportional to rule count beyond the response body buffer (single allocation for the formatted output).
- **NFR-003**: No new dependencies — implementation uses stdlib only, consistent with project constraints.

---

## Success Criteria

<!--
  Success criteria MUST be:
  - Measurable: include specific metrics (time, percentage, count)
  - Technology-agnostic: no mention of frameworks, languages, databases
  - User-focused: describe outcomes from user/business perspective
  - Verifiable: can be tested without knowing implementation details
-->

- **SC-001**: Operators can retrieve the full rule list in a single request-response exchange, with 100% of loaded rules represented in the output.
- **SC-002**: Existing protocol client parsers for multi-line responses (QUERY format) work unmodified for LISTRULES output.
- **SC-003**: All existing tests continue to pass — zero regressions introduced.
- **SC-004**: The command is documented in the protocol reference with request/response examples.

---

## Key Entities

<!--
  Include only if the feature involves data modeling.
  Describe entities at the domain level, not database schema.
-->

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| Rule | A mapping from a job name pattern to a runner that executes matching jobs | identifier, pattern, runner (shell or amqp) |
| Instruction (list_rules) | A read-only instruction requesting all configured rules | No payload fields |
| Response | The result of processing an instruction, optionally containing a multi-line body | request, success, body (optional) |

---

## Assumptions

<!--
  Document reasonable defaults and assumptions made during spec generation.
  These should be validated during the clarification step.
-->

- Rule count is small enough (< 10,000) that returning all rules in a single response is acceptable — no pagination needed.
- Hash map iteration order is non-deterministic and that is acceptable for this command — no ordering guarantee is provided.
- Extra trailing arguments after `LISTRULES` are silently ignored rather than producing an error, consistent with protocol tolerance patterns.
- The response format for runner args follows the same token format used by `RULE SET` input, enabling round-trip parsing.

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: medium
- **Estimation**: S

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

- The multi-line response pattern is identical to QUERY: each line prefixed with request ID, terminated by `<request_id> OK
`. This is established in `write_response` within `tcp_server.zig`.
- Rule storage uses `std.StringHashMapUnmanaged(Rule)` keyed by rule identifier. The `LISTRULES` handler iterates via `valueIterator()`.
- The `list_rules` variant joins `get` and `query` as read-only instructions that skip `append_to_logfile` in the scheduler.
- Runner display format: shell rules show the command string; AMQP rules show DSN, exchange, and routing key as space-separated tokens.
