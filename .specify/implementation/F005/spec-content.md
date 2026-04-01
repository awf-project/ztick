# F005: Add Startup Logging

## Scope

<!--
  Define what this feature covers and what it explicitly does NOT cover.
  This prevents scope creep and sets clear boundaries for implementation.
-->

### In Scope

- Wire `log_level` from Config to a runtime-configurable `std.log` custom log function
- Add structured log output at startup (config loaded, listening address, database state)
- Add runtime log output for significant events (client connect/disconnect, instruction processing, execution lifecycle)
- Update `docs/tutorials/getting-started.md` to reflect actual log output

### Out of Scope

- Structured logging formats (JSON, logfmt) — plain human-readable `[LEVEL] message` only
- Log output to file (stderr only)
- Log rotation or log file management
- Per-module log level filtering (single global level)

### Deferred

<!--
  Track work that was considered but intentionally postponed.
  Each item must have a rationale to prevent scope amnesia.
-->

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| Structured JSON log output | No machine consumers exist yet; plain text sufficient for v0.1.0 operators | future |
| Per-module log levels | Single global level covers all current use cases; three threads is not enough to warrant granular control | future |
| Log-to-file support | Operators can redirect stderr; dedicated file logging adds complexity without clear demand | future |
| OpenTelemetry instrumentation | Separate feature with broader observability scope already specified | F006 or future |

---

## User Stories

<!--
  User stories are PRIORITIZED vertical slices ordered by importance.
  Each story must be INDEPENDENTLY TESTABLE - implementing just ONE
  should deliver a viable MVP that provides user value.

  P1 = Must Have (MVP), P2 = Should Have, P3 = Nice to Have
-->

### US1: Startup Feedback (P1 - Must Have)

**As a** system operator,
**I want** ztick to print its configuration and listening address on startup,
**So that** I can confirm the process launched correctly and is reachable.

**Why this priority**: Without any startup output, operators cannot distinguish a successful launch from a silent hang. This is the minimum viable logging that makes ztick usable in production.

**Acceptance Scenarios:**
1. **Given** ztick is started with default config, **When** the process initializes, **Then** stderr contains a line showing the listening address `127.0.0.1:5678` at INFO level
2. **Given** ztick is started with `-c custom.toml` specifying `listen = "0.0.0.0:9999"`, **When** the process initializes, **Then** stderr contains a line showing `0.0.0.0:9999` as the listening address
3. **Given** ztick is started with `log_level = "off"` in config, **When** the process initializes, **Then** stderr contains no log output
4. **Given** ztick is started with a logfile containing 3 jobs and 2 rules, **When** the database loads, **Then** stderr contains a line showing the loaded job count (3) and rule count (2)

**Independent Test:** Start ztick with default config, capture stderr, verify it contains at least a listening address line.

### US2: Runtime Log Level Control (P1 - Must Have)

**As a** system operator,
**I want** the `log_level` config field to control which log messages appear,
**So that** I can increase verbosity when debugging or silence output in production.

**Why this priority**: The config field already exists and is parsed but has no effect. Wiring it is prerequisite for all logging to be useful — without level control, operators cannot tune verbosity.

**Acceptance Scenarios:**
1. **Given** `log_level = "warn"` in config, **When** an INFO-level event occurs, **Then** no output is produced for that event
2. **Given** `log_level = "debug"` in config, **When** an INFO-level event occurs, **Then** the event is logged to stderr
3. **Given** `log_level = "error"` in config, **When** startup completes normally, **Then** only ERROR-level messages (if any) appear on stderr

**Independent Test:** Start ztick with `log_level = "warn"`, verify INFO startup messages are suppressed; restart with `log_level = "info"`, verify they appear.

### US3: Connection Lifecycle Logging (P2 - Should Have)

**As a** system operator,
**I want** ztick to log client connections and disconnections,
**So that** I can monitor who is connecting and detect unexpected disconnects.

**Why this priority**: Connection visibility is the next most valuable diagnostic after startup confirmation. It helps operators debug client integration issues without reaching for external tools like `ss` or `tcpdump`.

**Acceptance Scenarios:**
1. **Given** ztick is running with `log_level = "info"`, **When** a client connects via TCP, **Then** stderr shows a log line with the client's address at INFO level
2. **Given** ztick is running with `log_level = "info"`, **When** a connected client disconnects, **Then** stderr shows a disconnect log line at INFO level

**Independent Test:** Start ztick, connect with `socat`, verify connect/disconnect lines appear on stderr.

### US4: Instruction and Execution Logging (P3 - Nice to Have)

**As a** system operator,
**I want** ztick to log received instructions and execution outcomes at DEBUG level,
**So that** I can trace the full lifecycle of a job from submission through execution.

**Why this priority**: Instruction-level tracing is verbose and primarily useful during development or incident investigation. Most operators will not enable DEBUG, making this a diagnostic enhancement rather than an operational necessity.

**Acceptance Scenarios:**
1. **Given** `log_level = "debug"`, **When** a SET instruction is received, **Then** stderr shows a DEBUG line identifying the instruction type and job identifier
2. **Given** `log_level = "debug"`, **When** a job execution completes (success or failure), **Then** stderr shows a DEBUG line with the job identifier and outcome

**Independent Test:** Start ztick with `log_level = "debug"`, send a SET command, verify instruction-received and execution-completed lines appear.

### Edge Cases

<!--
  Boundary conditions, error scenarios, and unusual states.
  Each edge case should map to at least one user story.
-->

- What happens when `log_level = "off"`? All log output must be suppressed, including startup messages. (US2)
- What happens when `log_level = "trace"`? All messages at every level must appear. (US2)
- How does the system handle logging when stderr is redirected to `/dev/null`? No change in behavior — logging writes to stderr regardless. (US1)
- What happens when the database logfile is empty or missing on startup? The loaded counts line should report 0 jobs and 0 rules. (US1)

---

## Requirements

<!--
  Use "System MUST" for mandatory requirements.
  Use "Users MUST be able to" for user-facing capabilities.
  Each requirement must be independently testable.
-->

### Functional Requirements

- **FR-001**: System MUST define a custom `std.log` function in `main.zig` that checks the runtime-configured log level before emitting messages
- **FR-002**: System MUST map `Config.LogLevel` values to `std.log.Level` equivalents, with `off` suppressing all output
- **FR-003**: System MUST log at INFO level on startup: the resolved config path (or "default" if none), the active log level, and the listening address
- **FR-004**: System MUST log at INFO level after database load: the count of loaded jobs and rules
- **FR-005**: System MUST log at INFO level when a TCP client connects or disconnects, including the client address
- **FR-006**: System MUST log at DEBUG level when an instruction is received, identifying the instruction type
- **FR-007**: System MUST log at DEBUG level when a job execution completes, identifying the job and success/failure
- **FR-008**: System MUST write all log output to stderr, never stdout
- **FR-009**: `docs/tutorials/getting-started.md` MUST be updated to show realistic log output matching the implementation

### Non-Functional Requirements

- **NFR-001**: Logging MUST NOT measurably impact tick loop throughput — log calls at levels below the configured threshold must short-circuit before formatting
- **NFR-002**: Log messages MUST NOT contain file paths to config files with potential secrets — log the path only, not the file contents
- **NFR-003**: Log format MUST be consistent: `[LEVEL] message
` with uppercase level name, single space separator
- **NFR-004**: Logging MUST be minimal — one line per significant event (startup, connection, instruction, execution), never per tick

---

## Success Criteria

<!--
  Success criteria MUST be:
  - Measurable: include specific metrics (time, percentage, count)
  - Technology-agnostic: no mention of frameworks, languages, databases
  - User-focused: describe outcomes from user/business perspective
  - Verifiable: can be tested without knowing implementation details
-->

- **SC-001**: Starting the process with default configuration produces at least 2 log lines on stderr within the first second (config and listening address)
- **SC-002**: Setting log level to "off" results in exactly 0 bytes written to stderr during startup and normal operation
- **SC-003**: Each of the 6 log levels (off, error, warn, info, debug, trace) correctly filters messages — verified by running with each level and counting output lines
- **SC-004**: Tutorial documentation matches actual process output — a new user following getting-started.md sees log messages consistent with what the document describes

---

## Key Entities

<!--
  Include only if the feature involves data modeling.
  Describe entities at the domain level, not database schema.
-->

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| LogLevel | Runtime verbosity threshold controlling which messages are emitted | off, error, warn, info, debug, trace (ordered by increasing verbosity) |

---

## Assumptions

<!--
  Document reasonable defaults and assumptions made during spec generation.
  These should be validated during the clarification step.
-->

- Zig's `std.log` can be overridden with a custom log function via `pub const std_options` in the root source file, and this custom function can check a runtime variable for the active level
- The runtime log level variable can be set once during initialization and read from any thread without synchronization (set-before-spawn pattern)
- stderr is the appropriate output stream; stdout is reserved for protocol responses (which use TCP, not stdout, but the principle holds)
- The `Scheduler` exposes or can expose job and rule counts after `load()` for the startup log line

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: medium
- **Estimation**: M

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

- Zig's `std.log` uses `pub const std_options` to set the log level at comptime. For runtime configuration, define a custom log function in `std_options` that reads a module-level `var log_level` variable set during `main()` initialization before any threads are spawned.
- The `Config.LogLevel` enum already matches `std.log.Level` names except for `off` and `trace`. The mapping function must handle `off` (suppress all) and `trace` (pass all) explicitly.
- The three-thread architecture (controller, database, processor) means log calls can come from any thread. `std.debug.print` (which backs `std.log` default) is already thread-safe via mutex on stderr.
- Keep log messages terse: `[INFO] listening on 127.0.0.1:5678` not `[INFO] The ztick scheduler is now listening for TCP connections on address 127.0.0.1:5678`.
