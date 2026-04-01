# Research: F012

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig (0.15.2) |
| Domain | CLI / TCP job scheduler |
| Task Type | feature (new protocol command) |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: Claude-mem sessions 18069-18075 contain extensive prior research on F012. Key discoveries:
- F012 spec created (18069) with 15 metrics across server health dimensions
- Architecture exploration (18072-18075) mapped all data sources: `job_storage.get_by_status()`, `rule_storage.rules.count()`, `execution_client.pending.items.len`, `execution_client.triggered.count()`, `active_process.status()`, `active_connections.load(.acquire)`
- Implementation plan (18070) established 15-task breakdown across 6 phases
- Technical specification (18071) positioned STAT as complementary to OpenTelemetry: OTel for continuous external monitoring, STAT for instant in-band diagnostics

Serena memory `F009/architecture_analysis` exists but is not directly relevant to F012.

Feature roadmap memory confirms F001-F005 implemented in v0.1.0; F006 (TLS), F009 (compression), F010 (telemetry) also merged. **F011 (authentication) is NOT merged into main** — auth_enabled will report `0` in current implementation.

**Sources**: claude-mem observations 18069-18075, Serena memory F009/architecture_analysis, feature_roadmap.md
**Recommendation**: Implementation can proceed without F011 dependency. Auth fields should be wired to report `0` (disabled) with a clear path to enable once F011 merges. STAT should still include the `auth_enabled` metric field for forward compatibility.

---

### Q1: [ARCH] What patterns should F012 follow?

**Finding**: STAT follows an established command flow pattern through 4 hexagonal layers:

1. **Domain Layer** (`src/domain/instruction.zig:4-27`): `Instruction` tagged union defines all commands. New variant `stat: struct {}` follows `list_rules: struct {}` pattern (line 26) for no-argument commands.

2. **Infrastructure Layer** (`src/infrastructure/tcp_server.zig:293-334`): `build_instruction()` parses TCP text into `Instruction` variants. Add "STAT" check returning `.{ .stat = .{} }`.

3. **Application Layer** (`src/application/query_handler.zig:25-92`): `handle()` method dispatches via switch on `request.instruction`. QUERY (lines 50-67) and LISTRULES (lines 70-88) are reference implementations for multi-line responses using `ArrayListUnmanaged(u8)` writer pattern.

4. **Response Formatting** (`src/infrastructure/tcp_server.zig:466-497`): `write_response()` splits body on `\n` and prefixes each line with `{request_id}`, terminating with `{request_id} OK\n`.

5. **Persistence Skip** (`src/application/scheduler.zig:127`): Read-only commands (`.get, .query, .list_rules`) skip persistence. STAT must be added here.

**Sources**: `src/domain/instruction.zig:4-27`, `src/infrastructure/tcp_server.zig:293-334,466-497`, `src/application/query_handler.zig:25-92`, `src/application/scheduler.zig:90-133`
**Recommendation**: Follow LISTRULES pattern exactly: `stat: struct {}` variant → `build_instruction()` parser case → `QueryHandler.handle()` switch arm → multi-line body with `ArrayListUnmanaged` writer → persistence skip. The spec's plan to handle STAT in Scheduler directly (bypassing QueryHandler) should be reconsidered — QueryHandler already handles all read-only multi-line commands, and metric data can be passed to it via context fields.

---

### Q2: [TYPES] Which types can F012 reuse?

**Finding**: All 15 STAT metrics map to existing types and fields:

| Metric | Source | Type | Access Pattern |
|--------|--------|------|----------------|
| `uptime_ns` | New field (capture at boot) | `i128` | `std.time.nanoTimestamp() - startup_ns` |
| `connections` | `tcp_server.active_connections` | `std.atomic.Value(usize)` | `.load(.acquire)` |
| `jobs_total` | `scheduler.job_storage.jobs` | `StringHashMapUnmanaged` | `.count()` |
| `jobs_planned` | `scheduler.job_storage` | via `get_by_status(.planned)` | `.len` on result |
| `jobs_triggered` | `scheduler.job_storage` | via `get_by_status(.triggered)` | `.len` on result |
| `jobs_executed` | `scheduler.job_storage` | via `get_by_status(.executed)` | `.len` on result |
| `jobs_failed` | `scheduler.job_storage` | via `get_by_status(.failed)` | `.len` on result |
| `rules_total` | `scheduler.rule_storage.rules` | `StringHashMapUnmanaged(Rule)` | `.count()` |
| `executions_pending` | `scheduler.execution_client.pending` | `ArrayListUnmanaged(Request)` | `.items.len` |
| `executions_inflight` | `scheduler.execution_client.triggered` | `AutoHashMapUnmanaged(u128, Request)` | `.count()` |
| `persistence` | `scheduler.persistence` | `?PersistenceBackend` (union: `.logfile` / `.memory`) | switch on tag |
| `compression` | `scheduler.active_process` | `?*Process` | null→idle, `.status()`→running/success/failure |
| `auth_enabled` | Config / not yet implemented | bool | `0` until F011 merges |
| `tls_enabled` | `config.controller_tls_cert` | `?[]const u8` | `!= null` |
| `framerate` | `config.database_framerate` | `u16` | direct read |

Key types to add:
- `Instruction.stat: struct {}` — new tagged union variant (domain layer)
- `ServerStats` struct — value object with 15 fields and `format()` method (domain layer)

**Sources**: `src/domain/instruction.zig:4-27`, `src/domain/job.zig:3-8`, `src/application/job_storage.zig:94-106`, `src/application/rule_storage.zig:7-50`, `src/application/execution_client.zig:12-84`, `src/application/scheduler.zig:18-242`, `src/infrastructure/tcp_server.zig:77-99`, `src/interfaces/config.zig:32-53`, `src/infrastructure/persistence/backend.zig:81-120`, `src/infrastructure/persistence/background.zig:8-12`
**Recommendation**: Create `ServerStats` as a plain struct in domain layer with a `pub fn format(self, allocator) ![]const u8` method that produces the multi-line response body. All fields are scalar types (integers, enums, booleans) — no heap allocations needed for the struct itself.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Established test patterns across the codebase:

1. **Co-located unit tests** in source files using `test "descriptive name" { ... }` blocks
2. **Allocator pattern**: `std.heap.GeneralPurposeAllocator(.{})` with `defer _ = gpa.deinit()` for leak detection
3. **Multi-line response verification**: `std.mem.splitScalar(u8, response.body.?, '\n')` loop for line counting, `std.mem.indexOf()` for substring presence
4. **Test naming convention**: `"VERB subject CONDITION returns EXPECTED"` (e.g., `"handle query instruction returns success with matching jobs in body"`)
5. **Response body cleanup**: `defer if (response.body) |b| allocator.free(b);`
6. **Persistence tests**: `std.testing.tmpDir()` for isolated file operations
7. **Non-persisting commands**: QUERY, GET, LISTRULES all verified to NOT call `append_to_persistence()`
8. **QueryHandler test setup**: allocator + GPA → storage objects → handler init → populate test data → call `handler.handle()` → assert response

Domain behavior from tests:
- `Response.body = null` for empty results (success=true) vs error (success=false)
- Multi-line body is newline-separated; `write_response()` handles request_id prefixing
- Status enum values: planned, triggered, executed, failed (all testable via `get_by_status()`)

**Sources**: `src/domain/instruction.zig:29-81`, `src/application/query_handler.zig:95-463`, `src/application/scheduler.zig:305-832`, `src/functional_tests.zig:20-584`
**Recommendation**: STAT tests should include:
- **Unit test** in query_handler.zig: verify all 15 metric keys present in response body, correct line count, success=true
- **Unit test** for ServerStats.format(): verify output format and key ordering
- **Functional test** in functional_tests.zig: end-to-end STAT via scheduler with pre-populated state
- **Negative test**: verify STAT does not persist to logfile

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: Strong historical precedents from F001, F002, and LISTRULES implementations:

1. **F002 (QUERY)** established multi-line response pattern: body as `?[]const u8` with newline separation, `write_response()` refactored to split and prefix lines with request_id
2. **LISTRULES** (commit `bbecaf5`) is the closest analog: no-argument, read-only, multi-line response, `list_rules: struct {}` variant — STAT follows this pattern exactly
3. **F001 (GET)** established `Response.body` extension with `?[]const u8 = null`
4. **ADR-0001**: Hexagonal architecture with strict 4-layer dependency direction
5. **ADR-0003**: TLS via system OpenSSL — `tls_enabled` metric derives from config cert presence
6. **ADR-0004**: OpenTelemetry SDK — STAT complements OTel (in-band vs out-of-band health)
7. **F011 (auth)** is NOT merged to main — `auth_enabled` should default to `0`

No TODO/FIXME markers found in affected files. No cleanup blockers detected.

**Sources**: `.specify/implementation/F002/spec-content.md`, `.specify/implementation/F002/research.md`, `docs/ADR/0001-hexagonal-architecture.md`, `docs/ADR/0003-openssl-tls-dependency.md`, `docs/ADR/0004-opentelemetry-sdk-dependency.md`, git log
**Recommendation**: Follow LISTRULES implementation path exactly. The established pattern is well-tested and requires no architectural deviations.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: No blocking cleanup required. Opportunities identified:

1. **Response formatting duplication** (Medium priority): QUERY (`query_handler.zig:58-66`) and LISTRULES (`query_handler.zig:75-87`) share identical `ArrayListUnmanaged(u8)` writer pattern. STAT will introduce a third instance. A shared helper could reduce duplication, but this is a refactoring concern beyond F012 scope.

2. **test_timing binary** (Low priority): Untracked 4MB binary in repo root, not in `.gitignore`. Should be added to `.gitignore` but is unrelated to F012.

3. **No dead code**: All public functions in affected files are referenced.
4. **No TODO/FIXME/HACK markers**: Clean codebase in affected modules.
5. **No existing health/stats mechanism**: STAT introduces new capability without replacing anything.

**Sources**: `src/application/query_handler.zig:58-87`, repo root `test_timing`
**Recommendation**: Do NOT extract a shared response formatting helper as part of F012 — it's out of scope and risks over-abstraction per CLAUDE.md guidelines ("Three similar lines of code is better than a premature abstraction"). Address `test_timing` separately.

## Best Practices

| Pattern | Application in F012 |
|---------|---------------------|
| Tagged union with `struct {}` payload | `Instruction.stat: struct {}` — consistent with `list_rules` for empty-payload commands |
| Multi-line response body | Build body as newline-separated string; `write_response()` handles request_id prefixing |
| ArrayListUnmanaged writer | Use `body_buf.writer(allocator).print(...)` for dynamic response body construction |
| Read-only persistence skip | Add `.stat` to the no-persist branch in `scheduler.zig` alongside `.get, .query, .list_rules` |
| Exhaustive switch | Zig compiler enforces all switch sites handle new `Instruction.stat` variant — no missed cases |
| Atomic cross-thread read | `active_connections.load(.acquire)` for safe usize read from scheduler thread |
| GPA test allocator | Use `GeneralPurposeAllocator` in tests for leak detection on response body |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| zig | 0.15.2 | Language/compiler | installed | none |
| zig-o11y/opentelemetry-sdk | v0.1.1 | Telemetry (not needed by STAT) | installed | none |
| libssl-dev | system | TLS (not needed by STAT) | installed | none |

No new dependencies required for F012. STAT reads only in-memory state using stdlib types.

## References

| File | Relevance |
|------|-----------|
| `src/domain/instruction.zig` | Add `stat: struct {}` variant to Instruction union |
| `src/domain/job.zig` | JobStatus enum for get_by_status() calls |
| `src/application/query_handler.zig` | Add `.stat` handler with multi-line response (reference: LISTRULES at lines 70-88) |
| `src/application/scheduler.zig` | Add `.stat` to persistence skip list; access job_storage, rule_storage, execution_client, active_process |
| `src/application/job_storage.zig` | `get_by_status()` method and `.jobs.count()` for job metrics |
| `src/application/rule_storage.zig` | `.rules.count()` for rules_total metric |
| `src/application/execution_client.zig` | `pending.items.len` and `triggered.count()` for execution metrics |
| `src/infrastructure/tcp_server.zig` | `build_instruction()` parser and `active_connections` atomic; `write_response()` for multi-line formatting |
| `src/infrastructure/persistence/backend.zig` | `PersistenceBackend` union tag for persistence type metric |
| `src/infrastructure/persistence/background.zig` | `Process.Status` union for compression status mapping |
| `src/interfaces/config.zig` | `controller_tls_cert`, `database_framerate` config fields |
| `src/main.zig` | Wiring: capture `startup_ns`, pass `active_connections` pointer to scheduler |
| `src/functional_tests.zig` | Add end-to-end STAT test |
| `.specify/implementation/F012/spec-content.md` | Feature specification with 15 metrics and protocol format |
| `.specify/implementation/F012/tasks.md` | 15-task implementation plan across 6 phases |
