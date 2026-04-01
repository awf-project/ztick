# Research: F006 — Add TLS Support to ztick Protocol

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig |
| Domain | CLI / TCP server |
| Task Type | feature |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: Project memories reveal critical context for F006:

1. **Architecture Decisions (ADRs 1-37)**: The project follows strict hexagonal architecture with 4 layers. TLS is an infrastructure concern — it should not touch domain or application layers. ADR 0002 explicitly chose zero external dependencies (`build.zig.zon dependencies = .{}`).

2. **Implementation Patterns**: Config extension follows a consistent pattern (add field to struct + parse section + deinit cleanup). Cross-cutting features like logging (F005) were wired at the interfaces layer (main.zig) with infrastructure adapters calling through stdlib mechanisms.

3. **Feature Roadmap**: C001, F001-F005 all IMPLEMENTED in v0.1.0. F006 is the first feature that may require relaxing the zero-dependency constraint.

4. **Session History (S427-S429)**: Recent work fixed socket address logging in tcp_server.zig, using `{f}` format specifier for `std.net.Address`. CI was updated from Zig 0.14.1 to `version: latest` (now 0.15.2 locally).

**Sources**: `architecture_decisions.md`, `implementation_patterns.md`, `feature_roadmap.md`, session observations 17174-17178
**Recommendation**: TLS implementation must follow hexagonal layering. The zero-dependency constraint needs an ADR (0003) since Zig stdlib lacks server-side TLS. Config extension follows the established F005 pattern.

---

### Q1: [ARCH] What patterns should F006 follow?

**Finding**: The codebase has strict 4-layer hexagonal architecture with barrel exports:

- `src/domain.zig` — 6 barrel imports (job, rule, runner, instruction, query, execution)
- `src/application.zig` — 5 barrel imports (job_storage, rule_storage, query_handler, execution_client, scheduler)
- `src/infrastructure.zig` — 6 barrel imports (channel, clock, shell_runner, tcp_server, persistence modules, protocol)
- `src/interfaces.zig` — 2 barrel imports (config, cli)

**TCP Server Architecture**: `TcpServer.start()` accepts connections and spawns per-connection worker threads. Each connection uses `std.net.Stream` directly — passed to `connection_worker()` → `handle_connection()` → `write_response()`. Stream operations: `stream.read()`, `stream.write()`, `stream.close()`.

**Config Flow**: Config parsed at entry point (`main.zig`), individual fields passed into thread context structs (`ControllerContext`, `DatabaseContext`, `ProcessorContext`). Infrastructure layer receives values but never imports config module directly.

**Reference Implementations**:
1. **F005 (Logging)**: Extended Config with `log_level` + `logfile_path`, wired in main.zig via `std_options.logFn`, infrastructure calls `std.log` directly. Cross-cutting pattern.
2. **F001 (GET command)**: Added `.get` instruction variant in domain, parser logic in `build_instruction()`, response handling in tcp_server. Protocol command pattern.

**Zig stdlib TLS**: `std.crypto.tls` exists but is **client-side only** in Zig 0.14.x/0.15.x. No `std.crypto.tls.Server` available. Server-side TLS requires either external library or C FFI bindings.

**Sources**: `src/infrastructure/tcp_server.zig:54-108,117-141,407-439`, `src/interfaces/config.zig:20-31`, `src/main.zig:105-130,385-452`, `build.zig.zon:5-6`, `docs/ADR/0001-hexagonal-architecture.md`, `docs/ADR/0002-zig-language-choice.md`
**Recommendation**: F006 follows the F005 "cross-cutting infrastructure" pattern (not a protocol command). Create Connection abstraction in infrastructure layer, extend Config in interfaces layer, wire in main.zig. An ADR (0003) is needed to decide how to provide server-side TLS given stdlib limitations — options: external Zig library via `build.zig.zon`, system OpenSSL FFI, or iguanaTLS.

---

### Q2: [TYPES] Which types can F006 reuse?

**Finding**: Key reusable types and the new abstractions needed:

**Domain types (unchanged)**:
- `Instruction` (`src/domain/instruction.zig:4-27`) — tagged union, no new variants needed
- `Request` / `Response` (`src/domain/query.zig:6-16`) — transport-agnostic DTOs
- `Client` (`src/domain/query.zig:4`) — `u128` identifier, works over any transport

**Infrastructure types to extend**:
- `std.net.Stream` — currently used directly in 10 locations in tcp_server.zig (lines 120, 132, 152, 218, 407, 413, 422, 427, 436, 566). Must be wrapped in a `Connection` abstraction.
- `TcpServer` (`src/infrastructure/tcp_server.zig:48-115`) — needs TLS context field, conditional TLS handshake in `start()`
- `ResponseRouter` (`src/infrastructure/tcp_server.zig:9-46`) — no changes needed, works with any connection
- `Channel(T)` (`src/infrastructure/channel.zig:3-99`) — generic, no changes needed

**Config type to extend**:
- `Config` (`src/interfaces/config.zig:20-32`) — add `controller_tls_cert: ?[]const u8` and `controller_tls_key: ?[]const u8` fields under `[controller]` section

**New types needed**:
- `Connection` — union or struct abstracting `std.net.Stream` and TLS stream. Must provide `read()`, `write()`, `close()` matching `std.net.Stream` interface.
- `TlsContext` — server-side TLS state loaded once at startup (cert chain + private key). Shared read-only across connections.

**Sources**: `src/domain/instruction.zig:4-27`, `src/domain/query.zig:4-16`, `src/infrastructure/tcp_server.zig:9-115`, `src/infrastructure/channel.zig:3-99`, `src/interfaces/config.zig:20-32`
**Recommendation**: Use a tagged union `Connection = union(enum) { plain: std.net.Stream, tls: TlsStream }` with methods delegating to the active variant. This matches the project's tagged union convention (ADR pattern). Place Connection type in infrastructure layer since it's a transport adapter.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Well-established test infrastructure across layers:

**Unit Tests (co-located in source files)**:
- `std.testing.allocator` for short-lived tests
- `make_socket_pair()` helper in tcp_server.zig (line 569) creates `SocketPair { read_fd, write_stream }` using Linux socketpair syscall
- Config tests use `expectError(ConfigError.X, result)` for validation failures
- Config tests always `defer cfg.deinit(allocator)` for cleanup
- Multi-line raw strings (`\\[section]\\nkey = "value"`) for TOML test content

**Concurrent Connection Tests** (tcp_server.zig lines 930-1014):
- Pattern: create socket pair → create channels → spawn responder thread with Context struct → call `handle_connection()` → join thread → assert
- Tests verify instruction forwarding, response routing, connection lifecycle

**Functional/Integration Tests** (`src/functional_tests.zig`):
- `std.heap.GeneralPurposeAllocator` for longer-lived objects
- Pattern: Setup → Execute → Verify State → Cleanup
- Helper functions: `build_logfile_bytes()`, `replay_into_scheduler()`
- Process-based CLI tests with stderr capture (F005 pattern at lines 639-727)

**Test Targets**:
- `make test` — unit tests (4 layers + main.zig)
- `make test-functional` — functional tests only
- `make test-all` — both

**Sources**: `src/infrastructure/tcp_server.zig:566-577,581-620,928-1014`, `src/interfaces/config.zig:129-194`, `src/functional_tests.zig:16-260,639-727`, `Makefile`, `build.zig`
**Recommendation**: F006 tests should include: (1) Config unit tests for TLS field parsing and partial-config validation using `expectError` pattern, (2) TCP server unit tests for Connection abstraction using `make_socket_pair()`, (3) Functional tests for TLS handshake and backward-compatible plaintext mode. TLS integration tests may need self-signed cert generation as test fixture.

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: Git history and ADRs reveal several critical precedents:

1. **Zero-dependency principle (ADR 0002)**: Explicitly chose no external packages. `build.zig.zon dependencies = .{}`. This is the main tension point for F006.

2. **Feature implementation pattern (F001-F005)**: Protocol commands follow domain→application→infrastructure chain. Cross-cutting features (F005 logging) follow config→main.zig→infrastructure pattern. TLS is cross-cutting infrastructure like F005.

3. **TCP server evolution**: Started simple, gained per-connection threading, then F005 added logging with `{f}` address formatting. Thread model (3 threads: controller/database/processor) is fixed — TLS handshake fits in controller thread's `connection_worker`.

4. **Config extension pattern**: Each feature adds fields to Config struct + parse section handling + deinit cleanup. F005 added `log_level` and `logfile_path` under `[log]` and `[database]` sections.

5. **Zig stdlib crypto**: Only `std.crypto.random.bytes()` used (execution_client.zig:35). No TLS/X.509 in stdlib as of 0.14.0/0.15.x. **This is the critical blocker.**

6. **No prior TLS work**: grep for tls/ssl/crypto/certificate found nothing beyond random bytes usage. No issues, branches, or TODOs about TLS.

**Sources**: `docs/ADR/0001-hexagonal-architecture.md`, `docs/ADR/0002-zig-language-choice.md`, `build.zig.zon:5-6`, `src/application/execution_client.zig:35`, git log
**Recommendation**: F006 requires ADR 0003 to address the zero-dependency constraint. Options: (a) add iguanaTLS or similar Zig-native TLS library via `build.zig.zon`, (b) use system OpenSSL via C FFI, (c) implement Connection abstraction now but defer actual TLS to when stdlib support matures. The spec notes in section "Clarifications" already anticipate this decision point.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: Analysis of files F006 will touch:

1. **Replaceable — Hardcoded `std.net.Stream` (10 occurrences)**: All direct stream references in tcp_server.zig must be replaced with a Connection abstraction. Locations: lines 120 (connection_worker param), 132 (handle_connection param), 152 (stream.read), 218 (stream.write), 407 (write_response param), 413/422/427/436 (write calls in write_response), 566/577 (test SocketPair).

2. **Duplication — Test harness patterns**: Two nearly identical Context structs and test setup in handle_connection tests (lines 930-971 and 973-1014). Could extract a shared test helper, saving ~30 lines.

3. **No dead code found**: All functions and imports in tcp_server.zig, config.zig, and main.zig are referenced and in use.

4. **No TODO/FIXME/deprecated markers** in affected files.

5. **Socket address logging (recently fixed)**: Lines 138-139 use `{f}` format specifier — working correctly after recent fix (S429).

**Sources**: `src/infrastructure/tcp_server.zig:120,132,152,218,407,413,422,427,436,566,577,930-1014`, `src/interfaces/config.zig:20-32,50-99`
**Recommendation**: Primary cleanup is the Connection abstraction replacing all 10 `std.net.Stream` references. Test helper extraction is optional but recommended during the refactoring pass. No deletions needed — this is additive work.

---

## Best Practices

| Pattern | Application in F006 |
|---------|----------------------------|
| Tagged union for domain concepts | `Connection = union(enum) { plain: std.net.Stream, tls: TlsStream }` with method delegation |
| Config extension with defaults | Add `controller_tls_cert: ?[]const u8 = null`, `controller_tls_key: ?[]const u8 = null` to Config |
| Barrel export for new modules | If Connection becomes its own file, add to `infrastructure.zig` barrel |
| `errdefer` cleanup on error paths | TLS context init must errdefer cleanup cert/key memory on failure |
| Set-before-spawn for config | TLS context loaded in main.zig before spawning controller thread |
| `expectError` for validation tests | Test partial TLS config with `expectError(ConfigError.InvalidValue, result)` |
| Socket pair for connection tests | Extend `make_socket_pair()` to test Connection abstraction |
| Cross-cutting at interfaces layer | TLS wiring in main.zig, TLS adapter in infrastructure |
| Persist zero-dependency ADR | Write ADR 0003 documenting dependency decision for TLS |
| Empty struct payloads for union variants | If Connection has variants without data, use `struct {}` |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| std.crypto.tls | stdlib | TLS client (no server support) | installed (insufficient) | Cannot use for server-side TLS |
| iguanaTLS | TBD | Zig-native TLS 1.3 library | missing | Evaluate: `build.zig.zon` dependency addition |
| System OpenSSL | >=1.1.1 | C FFI TLS implementation | system-level | Evaluate: adds platform dependency |
| bear-ssl (zig) | TBD | Alternative Zig TLS binding | missing | Evaluate as alternative to iguanaTLS |

**Critical Decision**: Zig 0.14.x/0.15.x `std.crypto.tls` is client-only. Server-side TLS requires one of the above options. This must be resolved in ADR 0003 before implementation begins.

## References

| File | Relevance |
|------|-----------|
| `src/infrastructure/tcp_server.zig` | Primary file to modify — Connection abstraction, TLS handshake, stream replacement |
| `src/interfaces/config.zig` | Config struct extension with tls_cert/tls_key fields and validation |
| `src/main.zig` | Wiring TLS context from config to TcpServer, set-before-spawn pattern |
| `src/infrastructure/channel.zig` | Channel(T) generic — no changes but understanding needed for response routing |
| `src/domain/query.zig` | Request/Response DTOs — transport-agnostic, no changes needed |
| `src/functional_tests.zig` | Integration test patterns, F005 CLI test pattern for TLS E2E tests |
| `docs/ADR/0001-hexagonal-architecture.md` | Architecture constraints for TLS placement |
| `docs/ADR/0002-zig-language-choice.md` | Zero-dependency principle that TLS may need to relax |
| `build.zig.zon` | Dependency declaration if external TLS library added |
| `build.zig` | Build system changes for TLS library linking |
