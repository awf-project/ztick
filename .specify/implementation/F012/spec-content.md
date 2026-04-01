# F012: Add STAT Command for Server Health Reporting

## Scope

### In Scope

- New `STAT` protocol command returning key-value server health metrics
- Multi-line response format consistent with QUERY and LISTRULES
- Server uptime tracking via startup timestamp recorded at boot
- Job counts by status (planned, triggered, executed, failed)
- Rule count, active connection count, pending/in-flight execution counts
- Persistence backend type and compression process status
- Configuration indicators: auth enabled, TLS enabled, framerate
- Read-only command with no persistence side effects
- Namespace-independent: STAT returns server-level data, not job-scoped data

### Out of Scope

- Memory allocator statistics (GPA introspection)
- Per-thread health or liveness probes
- Historical time-series data (use OpenTelemetry for that)
- Custom metric selection or filtering via arguments
- Machine-readable structured output (JSON mode)

### Deferred

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| JSON output mode | Line-based key-value is consistent with existing protocol; JSON adds parser complexity for minimal v1 gain | future |
| Memory statistics | GPA queryStats() is available but exposes allocator internals; defer until profiling is needed | future |
| Per-thread liveness | Would require heartbeat tracking per thread; shutdown coordination via atomic flag is sufficient for v1 | future |
| Filtered STAT | No arguments needed for v1; full dump is small (~15 lines) | future |

---

## User Stories

### US1: Query Server Health (P1 - Must Have)

**As a** server operator,
**I want** to send a `STAT` command and receive key health metrics,
**So that** I can verify the server is running correctly and inspect its current state without external tooling.

**Why this priority**: Operators currently have no in-band way to check server health. Log output requires server-side access and does not reflect live state. STAT provides a lightweight, protocol-native health check.

**Acceptance Scenarios:**
1. **Given** a running ztick server, **When** a client sends `<req_id> STAT\n`, **Then** the server responds with multiple `<req_id> <key> <value>\n` lines followed by `<req_id> OK\n`.
2. **Given** a server with 3 planned jobs and 1 executed job, **When** a client sends `STAT`, **Then** the response includes `jobs_planned 3` and `jobs_executed 1`.
3. **Given** a server started 60 seconds ago, **When** a client sends `STAT`, **Then** the response includes `uptime_ns` with a value approximately equal to 60 billion nanoseconds.
4. **Given** a server with auth enabled, **When** an authenticated client sends `STAT`, **Then** the response includes `auth_enabled 1`.

**Independent Test:** Connect to server, send `req-1 STAT\n`, verify response contains `req-1 uptime_ns <number>\n` and ends with `req-1 OK\n`.

### US2: Monitor Active Connections (P2 - Should Have)

**As a** server operator,
**I want** STAT to report the number of active TCP connections,
**So that** I can detect connection leaks or unexpected load.

**Why this priority**: Connection count is already tracked via `active_connections` atomic. Exposing it via STAT requires no new instrumentation, only reading an existing value.

**Acceptance Scenarios:**
1. **Given** 2 active TCP connections, **When** one of them sends `STAT`, **Then** the response includes `connections 2`.
2. **Given** a single connection, **When** it sends `STAT`, **Then** the response includes `connections 1` (the querying connection itself).

**Independent Test:** Open 3 connections, send `STAT` on one, verify `connections 3`.

### US3: Inspect Execution Pipeline (P2 - Should Have)

**As a** server operator,
**I want** STAT to report pending and in-flight execution counts,
**So that** I can detect job execution backlogs or stalled runners.

**Why this priority**: Execution backlog is invisible without this. A growing `executions_pending` indicates the processor thread cannot keep up.

**Acceptance Scenarios:**
1. **Given** no jobs are currently executing, **When** a client sends `STAT`, **Then** the response includes `executions_pending 0` and `executions_inflight 0`.
2. **Given** a slow-running shell command is executing, **When** a client sends `STAT`, **Then** `executions_inflight` is at least 1.

**Independent Test:** Send `STAT` on idle server, verify `executions_pending 0` and `executions_inflight 0`.

### US4: STAT Without Authentication (P1 - Must Have)

**As a** server operator with auth enabled,
**I want** STAT to require authentication like any other command,
**So that** unauthenticated clients cannot probe server internals.

**Why this priority**: STAT exposes operational details (connection count, job counts, persistence state). These must be gated behind auth when auth is enabled.

**Acceptance Scenarios:**
1. **Given** auth is enabled, **When** an authenticated client sends `STAT`, **Then** the server responds with health metrics.
2. **Given** auth is enabled, **When** an unauthenticated client sends `STAT` as first command, **Then** the server responds `ERROR\n` and closes the connection (standard auth enforcement).
3. **Given** auth is disabled, **When** any client sends `STAT`, **Then** the server responds with health metrics.

**Independent Test:** With auth enabled, authenticate then send `STAT`, verify `OK`. Without auth, send `STAT` directly, verify `OK`.

### Edge Cases

- What happens when a client sends `STAT` with extra arguments? Extra arguments are silently ignored (same behavior as LISTRULES).
- Does STAT require namespace authorization? No — STAT reports server-level metrics, not job-scoped data. Any authenticated client can call STAT regardless of namespace.
- What if uptime overflows? Uptime is stored as `i64` nanoseconds. At ~292 years this overflows, which is not a practical concern.
- Is the STAT response atomic? No — values are read sequentially from different sources within a single scheduler tick. Minor inconsistencies between counters are acceptable.

---

## Requirements

### Functional Requirements

- **FR-001**: System MUST support `STAT` as a new protocol command with no required arguments.
- **FR-002**: System MUST respond to `STAT` with multiple key-value lines in format `<request_id> <key> <value>\n`, terminated by `<request_id> OK\n`.
- **FR-003**: System MUST include the following metrics in STAT response:
  - `uptime_ns` — server uptime in nanoseconds since startup
  - `connections` — number of active TCP connections
  - `jobs_total` — total number of jobs in storage
  - `jobs_planned` — count of jobs with status `planned`
  - `jobs_triggered` — count of jobs with status `triggered`
  - `jobs_executed` — count of jobs with status `executed`
  - `jobs_failed` — count of jobs with status `failed`
  - `rules_total` — total number of rules in storage
  - `executions_pending` — number of jobs queued for execution
  - `executions_inflight` — number of jobs currently being executed
  - `persistence` — backend type (`logfile` or `memory`)
  - `compression` — compression process status (`idle`, `running`, `success`, `failure`)
  - `auth_enabled` — `1` if auth is configured, `0` otherwise
  - `tls_enabled` — `1` if TLS is configured, `0` otherwise
  - `framerate` — configured scheduler tick rate
- **FR-004**: System MUST NOT persist STAT commands to the logfile (read-only operation).
- **FR-005**: System MUST treat STAT as namespace-independent — any authenticated client can call it regardless of namespace prefix.
- **FR-006**: System MUST enforce authentication for STAT when auth is enabled (standard auth flow applies).
- **FR-007**: System MUST silently ignore extra arguments passed to STAT.

### Non-Functional Requirements

- **NFR-001**: STAT response MUST complete in under 1ms (all data is in-memory reads).
- **NFR-002**: STAT MUST NOT block the scheduler tick loop — it reads state within the existing query handler cycle.
- **NFR-003**: STAT response MUST maintain consistent key ordering across invocations for scripting reliability.

---

## Success Criteria

- **SC-001**: `STAT` returns all 15 metrics with correct values verified by functional tests.
- **SC-002**: STAT does not produce any logfile entries (read-only).
- **SC-003**: STAT works with and without authentication enabled.
- **SC-004**: STAT response follows the multi-line response pattern identical to QUERY and LISTRULES.
- **SC-005**: All existing tests continue to pass (no regressions).

---

## Protocol Format

### Request

```
<request_id> STAT\n
```

### Response

```
<request_id> uptime_ns 60000000000\n
<request_id> connections 3\n
<request_id> jobs_total 42\n
<request_id> jobs_planned 30\n
<request_id> jobs_triggered 2\n
<request_id> jobs_executed 8\n
<request_id> jobs_failed 2\n
<request_id> rules_total 5\n
<request_id> executions_pending 1\n
<request_id> executions_inflight 1\n
<request_id> persistence logfile\n
<request_id> compression idle\n
<request_id> auth_enabled 1\n
<request_id> tls_enabled 0\n
<request_id> framerate 512\n
<request_id> OK\n
```

---

## Key Entities

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| ServerStats | Value object aggregating all health metrics | All 15 metric fields |
| Instruction.stat | New tagged union variant for the STAT command | `struct {}` (no payload, consistent with list_rules) |

---

## Assumptions

- STAT reads from existing in-memory state; no new data collection infrastructure is needed.
- The `active_connections` atomic in tcp_server.zig is readable from the scheduler thread (cross-thread atomic read).
- Startup timestamp is recorded once at server boot and never changes.
- Compression status reflects the last known state of the background compression process.
- Key ordering in response is fixed (alphabetical would be confusing; use logical grouping instead).

---

## Metadata

- **Status**: backlog
- **Version**: v0.2.0
- **Priority**: medium
- **Estimation**: M

## Dependencies

- **Blocked by**: none
- **Unblocks**: none

## Related

- F010 (OpenTelemetry) — STAT provides in-band health; OTel provides out-of-band metrics export
- F011 (Authentication) — STAT respects auth enforcement
- F006 (TLS) — STAT reports TLS enabled status

## Notes

- STAT follows the same architectural path as LISTRULES: no-argument read-only command, multi-line response, no persistence.
- The `active_connections` atomic must be passed to the scheduler or query handler. The cleanest approach is passing it via the `ServerStats` struct built in the query handler, reading the atomic value provided at construction.
- Uptime calculation: store `startup_ns = std.time.nanoTimestamp()` in main, pass to scheduler, compute `uptime_ns = now - startup_ns` at STAT time.
- Compression status maps from the `active_process` field: null → `idle`, process running → `running`, last result success → `success`, last result failure → `failure`.
