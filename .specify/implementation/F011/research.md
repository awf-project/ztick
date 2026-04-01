# Research: F011 - Add Client Authentication to ztick Protocol

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig 0.15.2 |
| Domain | TCP protocol server / CLI scheduler |
| Task Type | feature |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: Project memories provide extensive context from 10 prior features (C001, F001-F010). Key patterns:
- Hexagonal architecture with 4 strict layers is well-established (ADR 0001)
- Config-driven optional features follow a consistent pattern: optional field in Config struct, fail-fast validation, set-before-spawn initialization, backward compatibility when unset
- F006 (TLS) is the closest predecessor: added optional `controller_tls_cert`/`controller_tls_key` to `[controller]` section, created infrastructure adapter (`tls_context.zig`), wrapped transport in `Connection` tagged union, conditional system library linking
- F008 (PersistenceBackend) shows the tagged union backend pattern with config enum selection
- Implementation patterns doc lists 68 patterns; most relevant: #36 C interop, #37 Connection union, #40 optional config pair validation, #41 TLS context as shared read-only resource, #51 persistence backend extraction, #55 config enum with default fallback
- Architecture decisions doc lists 67 ADRs; F011 should follow ADR patterns for optional features

**Sources**: `implementation_patterns.md`, `architecture_decisions.md`, `feature_roadmap.md`, Serena memory `F009/architecture_analysis`, claude-mem observation #17519 (F011 spec prepared)
**Recommendation**: Follow F006 TLS pattern closely for config extension, infrastructure adapter, and connection-scoped state. Auth file parsing reuses the custom TOML parser pattern from config.zig.

---

### Q1: [ARCH] What patterns should F011 follow?

**Finding**: The codebase uses hexagonal architecture with 4 layers and barrel exports. F011 touches all layers:

**Domain layer** (`src/domain/`): Add `auth.zig` with `Token` and `ClientIdentity` structs. Token holds name/secret/namespace as `[]const u8`. ClientIdentity holds name/namespace only (FR-011: secret not retained after auth).

**Application layer** (`src/application/`): Add `token_store.zig` with `TokenStore` struct following `RuleStorage`/`JobStorage` pattern (allocator + `StringHashMapUnmanaged`). Methods: `authenticate(secret) ?ClientIdentity`, `is_authorized(identity, identifier) bool`.

**Infrastructure layer** (`src/infrastructure/`): Modify `tcp_server.zig` to add AUTH handshake in `handle_connection()` before the main command loop. AUTH is handled at the connection level (like TLS handshake), not as a regular Instruction dispatched to the scheduler. Add auth file TOML parser as a new infrastructure module.

**Interfaces layer** (`src/interfaces/`): Extend `config.zig` with `controller_auth_file: ?[]const u8 = null` in Config struct, parsing in `[controller]` section.

**Main wiring** (`src/main.zig`): Load auth file if configured, create TokenStore, pass to TcpServer via set-before-spawn pattern (like TlsContext).

**Key integration points**:
- `handle_connection()` (tcp_server.zig:189-291): AUTH check before command dispatch loop
- `build_instruction()` (tcp_server.zig:293-334): No AUTH variant needed here; AUTH handled separately
- Config parse (config.zig:106-118): Add `auth_file` key after `tls_key`
- QUERY filtering at response serialization time in connection handler, not in scheduler (per spec note)

**Sources**: `src/domain.zig`, `src/application.zig`, `src/infrastructure.zig`, `src/interfaces.zig`, `src/infrastructure/tcp_server.zig:189-291`, `src/interfaces/config.zig:32-186`, `src/main.zig`
**Recommendation**: Create 2 new files (`src/domain/auth.zig`, `src/application/token_store.zig`), modify 4 existing files (`config.zig`, `tcp_server.zig`, `main.zig`, barrel exports). Follow F006 TLS pattern for optional config-driven feature with connection-scoped state.

---

### Q2: [TYPES] Which types can F011 reuse?

**Finding**: Extensive type reuse available:

| Type | File | Reuse |
|------|------|-------|
| `Job.identifier: []const u8` | domain/job.zig:10-14 | Identifier pattern for Token fields |
| `Rule.supports(job)` | domain/rule.zig:6-17 | Prefix matching pattern for namespace checks |
| `Instruction` tagged union | domain/instruction.zig:4-27 | Pattern for tagged unions with struct payloads; AUTH NOT added here |
| `Response{success, body}` | domain/query.zig:12-16 | OK/ERROR response format; AUTH uses same response wire format |
| `Client = u128` | domain/query.zig:4 | Client identifier type |
| `Config` struct | interfaces/config.zig:32-53 | Optional field pattern (`?[]const u8 = null`) from TLS fields |
| `ConfigError` | interfaces/config.zig:24-30 | Error enum pattern; extend for auth validation errors |
| `Connection` union | infrastructure/tcp_server.zig:12-28 | Transport abstraction; auth state is SEPARATE (not a Connection variant) |
| `RuleStorage` | application/rule_storage.zig:7-50 | StringHashMap + methods pattern for TokenStore |
| `JobStorage.get_by_prefix()` | application/job_storage.zig:65-77 | Prefix filtering with `std.mem.startsWith` for QUERY namespace filtering |
| `std.mem.startsWith` | stdlib | Namespace prefix matching (already used in Rule.supports()) |
| `std.crypto.utils.timingSafeEql` | stdlib | Constant-time comparison for secret matching (verify availability in 0.15.2) |

**Design decisions**:
- AUTH is NOT an Instruction variant; it's handled at connection setup before command dispatch
- ClientIdentity is connection-scoped local state in `handle_connection()`, not stored in Request
- TokenStore is read-only after startup (no persistence needed, no Entry variant needed)
- Namespace enforcement happens in the connection handler for QUERY filtering, and via an authorization check wrapper for other commands

**Sources**: `src/domain/instruction.zig:4-27`, `src/domain/query.zig:4-16`, `src/interfaces/config.zig:24-53`, `src/infrastructure/tcp_server.zig:12-28`, `src/application/rule_storage.zig:7-50`, `src/application/job_storage.zig:65-77`
**Recommendation**: Reuse StringHashMap pattern for TokenStore, prefix matching for namespace checks, optional config field pattern for auth_file. Verify `std.crypto.utils.timingSafeEql` availability before implementation.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Tests are co-located in source files via `test` blocks. Functional tests in `src/functional_tests.zig`.

**Unit test patterns**:
- Allocator: `std.testing.allocator` or `GeneralPurposeAllocator`
- Cleanup: Consistent `defer deinit()` pattern
- Naming: Descriptive behavior-oriented names (e.g., "tick transitions planned job to triggered when rule matches")
- Assertions: `std.testing.expect()`, `std.testing.expectEqual()`, `std.testing.expectEqualStrings()`

**Functional test patterns**:
- `TestServer` helper (functional_tests.zig:693-728): Spawns ztick process with temp config, manages lifecycle
- `spawn_ztick()` (functional_tests.zig:645-655): Process spawning with stderr capture
- `make_socket_pair()` (tcp_server.zig:623-638): Socket pairs for connection testing without real TCP
- `drain_stderr()` (functional_tests.zig:657-670): Non-blocking stderr reading for log verification
- TLS test fixtures in `test/fixtures/tls/`

**Test counts**: ~342 test blocks across codebase; 42+ functional tests; 39 TCP server tests; 26+ config tests

**Business rules from tests**:
- Config validation: Invalid log level, framerate out of range, unknown key/section, partial TLS config all fail at parse time
- Protocol parsing: Bare newline is Invalid, no newline is Incomplete, quoted strings and escapes handled
- Connection lifecycle: Clean disconnect, deregistration from router, response routing to correct client
- Response format: Multi-line body prefixed with request_id per line, terminated by OK/ERROR

**F011 test requirements**:
- Unit tests in `src/domain/auth.zig`: Token/ClientIdentity struct construction
- Unit tests in `src/application/token_store.zig`: authenticate(), is_authorized(), duplicate secret detection, empty namespace rejection
- Unit tests in `src/interfaces/config.zig`: auth_file parsing, missing file error, default (no auth)
- Unit tests in `src/infrastructure/tcp_server.zig`: AUTH handshake via socketpair, namespace enforcement on commands
- Functional tests in `src/functional_tests.zig`: Full E2E with auth file, valid/invalid auth, namespace allow/deny, backward compatibility (no auth_file)
- Test fixtures: `test/fixtures/auth/` with sample auth TOML files
- Constant-time comparison test: Verify equal execution path regardless of prefix match length (SC-005)

**Sources**: `src/functional_tests.zig:645-728`, `src/infrastructure/tcp_server.zig:500-950`, `src/application/scheduler.zig:245+`, `src/interfaces/config.zig:207+`
**Recommendation**: Follow existing patterns exactly. Create test fixtures in `test/fixtures/auth/`. Use socketpair for auth handshake unit tests. Use TestServer helper for functional E2E auth tests.

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: F011 is the first authentication feature in ztick. No prior auth-related commits or code.

**Most relevant predecessors**:
1. **F006 TLS** (commit `c2955e6`, 2026-03-30): Direct pattern match - optional config-driven security feature with connection-scoped state. 24 files modified, 933 insertions. Added Connection union, TlsContext infrastructure module, conditional system library linking, both-or-neither config validation.
2. **F008 Persistence** (commit `4abbf35`, 2026-03-31): Config-driven feature selection via enum. PersistenceBackend tagged union, optional backend in Scheduler.
3. **F009 Compression** (commit `43e721e`, 2026-03-31): Time-based scheduling in tick loop, Process polling for background work.

**ADR precedents**:
- ADR 0001: Hexagonal architecture - auth must respect layer boundaries
- ADR 0002: Zig language choice - zero-dependency preference (F011 needs no new deps; `std.crypto.utils` is stdlib)
- ADR 0003: System OpenSSL - precedent for security infrastructure in dedicated module
- ADR 0004: OpenTelemetry SDK - precedent for justified dependency additions

**F011 likely does NOT need a new ADR**: No new dependencies required. `std.crypto.utils.timingSafeEql` is in Zig stdlib. Auth file parsing reuses existing custom TOML parser pattern. No system libraries needed.

**Feature progression**: C001 (core) -> F001-F004 (protocol commands) -> F005 (logging) -> F006 (TLS) -> F007 (dump CLI) -> F008 (persistence backends) -> F009 (compression) -> F010 (telemetry) -> **F011 (auth)**

**Sources**: Git log, `docs/ADR/0001-0004`, `CHANGELOG.md`, `.specify/implementation/` directories
**Recommendation**: Follow F006 TLS implementation pattern most closely. No new ADR needed. Document auth_file format in existing config documentation.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: 3 cleanup opportunities identified, 1 significant:

1. **AMQP Runner Dead Code** - `src/infrastructure/shell_runner.zig:10`, `src/domain/runner.zig:5-9`, `src/infrastructure/tcp_server.zig:350-369`, plus encoder, query_handler, dump references
   - AMQP variant exists in Runner union but returns `error.UnsupportedRunner`
   - Scaffolding throughout protocol parsing, persistence encoding, dump formatting
   - **Risk: LOW** - AMQP is documented as deferred; removing cleans up ~50 lines across 6 files
   - **Recommendation**: OUT OF SCOPE for F011. Clean up separately if desired.

2. **Duplicated TOML Parsing Pattern** - `src/interfaces/config.zig:100-162`
   - String value allocation/duplication pattern repeated 6+ times across sections
   - Adding auth_file will add another copy
   - **Risk: LOW** - Extracting helper improves DRY
   - **Recommendation**: OUT OF SCOPE for F011. The copy-paste pattern is the established convention; changing it would be a separate refactor.

3. **No Auth Stubs Found** - No placeholder auth/token/security code exists
   - Clean slate for F011 implementation
   - No TODO/FIXME related to authentication
   - **Recommendation**: F011 adds entirely new code; no cleanup needed.

**Sources**: Grep results for auth/token/secret/namespace/TODO/FIXME across `src/`
**Recommendation**: No cleanup blocking F011. AMQP removal and config parser DRY improvement are separate concerns. Proceed with additive implementation.

## Best Practices

| Pattern | Application in F011 |
|---------|----------------------------|
| Optional config field (`?[]const u8 = null`) | `controller_auth_file` in Config struct, null when auth disabled |
| Set-before-spawn initialization | Load TokenStore in main(), pass to TcpServer before spawning controller thread |
| Connection-scoped state | ClientIdentity stored as local variable in handle_connection(), not in Connection union |
| Prefix matching (`std.mem.startsWith`) | Namespace enforcement on identifiers (reuse Rule.supports() pattern) |
| Fail-fast config validation | Reject invalid auth file (missing secrets, duplicate secrets, empty namespaces) at startup |
| Tagged union with struct payloads | Token and ClientIdentity as plain structs (not union variants); no new Instruction variant for AUTH |
| StringHashMap storage pattern | TokenStore uses StringHashMapUnmanaged for O(1) token lookup by secret |
| errdefer cleanup on error paths | Auth file parsing frees partial allocations on error |
| Constant-time comparison | `std.crypto.utils.timingSafeEql` for secret matching (FR-008) |
| Co-located unit tests | Test blocks in auth.zig, token_store.zig; functional tests in functional_tests.zig |
| Infrastructure adapter isolation | Auth file parsing and token validation logic in infrastructure layer module |
| Response format consistency | AUTH OK/ERROR uses same `write_response()` format as other commands |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| Zig stdlib (`std.crypto.utils`) | 0.15.2 | `timingSafeEql` for constant-time secret comparison | installed | Verify function signature in 0.15.2 stdlib |
| Zig stdlib (`std.mem`) | 0.15.2 | `startsWith` for namespace prefix matching | installed | none |
| No new external dependencies | - | F011 uses only Zig stdlib | - | none |

## References

| File | Relevance |
|------|-----------|
| `src/infrastructure/tcp_server.zig` | Primary modification target: AUTH handshake in handle_connection(), namespace enforcement before command dispatch |
| `src/interfaces/config.zig` | Add auth_file config field and parsing in [controller] section |
| `src/main.zig` | Wire TokenStore creation and pass to TcpServer |
| `src/domain/instruction.zig` | Reference for tagged union pattern (AUTH NOT added here) |
| `src/domain/query.zig` | Request/Response types; ClientIdentity follows same struct pattern |
| `src/application/rule_storage.zig` | Template for TokenStore (StringHashMap + methods) |
| `src/application/job_storage.zig` | get_by_prefix() pattern for namespace-filtered QUERY |
| `src/application/query_handler.zig` | Command dispatch; namespace checks needed here or in caller |
| `src/infrastructure/tls_context.zig` | F006 reference: infrastructure adapter for security feature |
| `src/functional_tests.zig` | Test infrastructure: TestServer helper, spawn_ztick, socketpair |
| `src/infrastructure/protocol/parser.zig` | Protocol parser; AUTH command parsed as normal line (command + args) |
| `src/domain.zig` | Barrel export; add auth module |
| `src/application.zig` | Barrel export; add token_store module |
| `docs/ADR/0003-openssl-tls-dependency.md` | Closest ADR precedent for security feature |
| `test/fixtures/tls/` | Test fixture pattern; create `test/fixtures/auth/` similarly |
