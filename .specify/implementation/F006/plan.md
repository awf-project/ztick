# Implementation Plan: F006

## Summary

Add TLS support to ztick's TCP server by introducing a `Connection` abstraction that wraps either a plain `std.net.Stream` or a `std.crypto.tls` stream, extending `Config` with `tls_cert`/`tls_key` fields under `[controller]`, and wiring TLS context initialization through `main.zig`. Since Zig stdlib lacks server-side TLS (`std.crypto.tls` is client-only in 0.15.2), the implementation will use Zig's C interop to link against system OpenSSL/libssl for the TLS handshake and stream wrapping.

## Constitution Compliance

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal Architecture | COMPLIANT | TLS is an infrastructure adapter concern; domain/application layers unchanged. Connection abstraction lives in infrastructure, config extension in interfaces, wiring in main.zig |
| TDD Methodology | COMPLIANT | Each component has co-located unit tests; functional tests validate E2E TLS connections |
| Zig Idioms | COMPLIANT | Error unions for TLS init failures, errdefer for cleanup, explicit allocator passing for cert/key buffers |
| Minimal Abstraction | DEVIATION | Connection abstraction has only 1 implementation initially (plain TCP); TLS adds the 2nd. Justified: spec explicitly requires Connection type (FR-008) and it enables future Unix socket transport |

Constitution: From `.specify/memory/constitution.md`

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.15.2 (minimum 0.14.0) |
| Framework | stdlib only (currently zero external deps) |
| Architecture | 4-layer hexagonal: domain → application → infrastructure → interfaces |
| Key patterns | Tagged unions, error unions, barrel exports, Channel(T) inter-thread comms, set-before-spawn config wiring, co-located test blocks, socketpair test helpers |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | Which TLS library to use given `std.crypto.tls` is client-only? | Use system OpenSSL via Zig's `@cImport`/C linkage. Zig has first-class C interop with zero overhead, and OpenSSL is universally available on deployment targets. | `build.zig.zon:6` shows `dependencies = .{}`; Zig's C interop is stdlib-native (not an external Zig package), preserving the spirit of minimal deps. `/usr/lib/zig/std/crypto/tls/` contains only `Client.zig` — confirmed no server-side TLS in stdlib. |
| A2 | Connection type: tagged union vs vtable? | Tagged union `Connection = union(enum) { plain, tls }` with methods, matching project's tagged union convention for domain concepts. | `src/domain/instruction.zig` uses `Instruction = union(enum)` pattern; `src/domain/runner.zig` uses same. CLAUDE.md: "Use tagged unions for protocol and runner types." |
| A3 | Where to place Connection type? | In `tcp_server.zig` alongside `TcpServer` and `ResponseRouter`, not a separate file. Connection is a transport-internal abstraction used only within tcp_server. | All TCP abstractions (TcpServer, ResponseRouter, SocketPair, connection_worker, handle_connection, write_response) are co-located in `src/infrastructure/tcp_server.zig:1-1015`. |
| A4 | How to pass TLS context from Config to TcpServer? | Add `tls_context: ?*TlsContext` field to `ControllerContext` struct in main.zig, loaded before spawning controller thread (set-before-spawn pattern). | `src/main.zig:105-111` shows `ControllerContext` struct with config values; `src/main.zig:416-422` shows set-before-spawn wiring. F005 used same pattern for `log_level`. |
| A5 | Should TLS context be its own file or part of tcp_server.zig? | Separate file `src/infrastructure/tls_context.zig` to isolate all C interop and OpenSSL FFI in one module, keeping tcp_server.zig clean. | Principle 1 (hexagonal arch) keeps adapters in infrastructure. Principle 4 (minimal abstraction) — the C FFI boundary is a natural module boundary. `src/infrastructure.zig:1-6` shows barrel exports per infrastructure module. |

## Approach Comparison

| Criteria | Approach A: System OpenSSL via C interop | Approach B: Pure Connection abstraction (defer TLS) | Approach C: Zig-native TLS library (iguanaTLS) |
|----------|----------------------------------------|---------------------------------------------------|------------------------------------------------|
| Description | Link system libssl/libcrypto via `@cImport`, implement TlsContext and TLS stream wrapping | Implement Connection abstraction only, stub TLS variant as compile error | Add iguanaTLS as `build.zig.zon` dependency for pure-Zig server TLS |
| Files touched | 5 (config, tcp_server, tls_context (new), main, infrastructure barrel, build.zig) | 3 (config, tcp_server, main) | 5 (config, tcp_server, tls_context (new), main, build.zig.zon) |
| New abstractions | 2 (Connection, TlsContext) | 1 (Connection) | 2 (Connection, TlsContext) |
| Risk level | Med (C interop is well-tested in Zig but adds system dependency) | Low (no TLS, just abstraction) | High (iguanaTLS compatibility with Zig 0.15.2 unverified, unmaintained) |
| Reversibility | Easy (remove linkLibC + tls_context.zig) | Easy | Hard (dependency lock-in) |

**Selected: Approach A (System OpenSSL via C interop)**

**Rationale:** The spec requires functional TLS (FR-001, US1), not just an abstraction. Approach B defers the core deliverable. Approach C adds an unverified Zig package dependency to a zero-dependency project. Zig's C interop is a first-class language feature (not an "external dependency" in the `build.zig.zon` sense), and system OpenSSL is universally available and battle-tested. This preserves `build.zig.zon dependencies = .{}` while delivering actual TLS.

**Trade-off accepted:** Adds platform dependency on system libssl. Mitigated by: OpenSSL is installed on every Linux/macOS server; build.zig can conditionally link only when TLS source files are present. Plaintext-only builds remain zero-dependency.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| System OpenSSL via `@cImport` | Zig's C interop is zero-overhead and first-class; keeps `build.zig.zon dependencies = .{}`; OpenSSL is the de facto standard for server TLS | iguanaTLS (Zig 0.15.2 compat unknown, possibly unmaintained), hand-written TLS (security risk) |
| Connection as tagged union in tcp_server.zig | Matches project convention for tagged unions; keeps all TCP abstractions co-located; avoids over-engineering | Vtable/interface (not idiomatic Zig for 2 variants), trait-like comptime generics (overcomplicated) |
| TlsContext as separate infrastructure module | Isolates all C FFI at a clean module boundary; infrastructure barrel export keeps it discoverable | Embedding in tcp_server.zig (would bloat a 1015-line file with C interop concerns) |
| ADR 0003 for OpenSSL dependency | Documents the first relaxation of zero-dependency principle; required by project governance (ADR 0002 explicitly chose zero deps) | No ADR (would leave architectural tension undocumented) |
| Conditional TLS linking in build.zig | `exe.linkSystemLibrary("ssl")` only when TLS module exists; plaintext builds stay dependency-free | Always link (breaks zero-dep promise for non-TLS users) |

## Components

```json
[
  {
    "name": "extend_config_tls_fields",
    "project": "",
    "layer": "interfaces",
    "description": "Add controller_tls_cert and controller_tls_key optional fields to Config struct, parse them under [controller] section, validate both-or-neither constraint, free allocations in deinit",
    "files": ["src/interfaces/config.zig"],
    "tests": ["src/interfaces/config.zig"],
    "dependencies": [],
    "user_story": "US2, US3",
    "verification": {
      "test_command": "zig build test-interfaces",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "tls_context_openssl_adapter",
    "project": "",
    "layer": "infrastructure",
    "description": "Create TlsContext struct wrapping OpenSSL SSL_CTX initialization from PEM cert/key files. Provides create() returning initialized context or error, and per-connection accept() performing TLS handshake on a raw fd. Includes deinit for cleanup.",
    "files": ["src/infrastructure/tls_context.zig"],
    "tests": ["src/infrastructure/tls_context.zig"],
    "dependencies": ["extend_config_tls_fields"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-infrastructure",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "connection_abstraction",
    "project": "",
    "layer": "infrastructure",
    "description": "Add Connection tagged union (plain: std.net.Stream, tls: TlsStream) with read(), write(), close() methods to tcp_server.zig. Replace all 10 direct std.net.Stream references in handle_connection and write_response with Connection. Update SocketPair test helper.",
    "files": ["src/infrastructure/tcp_server.zig"],
    "tests": ["src/infrastructure/tcp_server.zig"],
    "dependencies": ["tls_context_openssl_adapter"],
    "user_story": "US1, US2, US4",
    "verification": {
      "test_command": "zig build test-infrastructure",
      "expected_output": "All 0 tests passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "wire_tls_through_main",
    "project": "",
    "layer": "interfaces",
    "description": "Extend ControllerContext with tls_context field. In main(), load TLS context from config cert/key paths before spawning controller thread. Pass to TcpServer.init. TcpServer.start performs TLS handshake on accepted connections when context is non-null. Update infrastructure.zig barrel export for tls_context module. Update build.zig to conditionally link libssl/libcrypto.",
    "files": ["src/main.zig", "src/infrastructure.zig", "build.zig"],
    "tests": ["src/main.zig"],
    "dependencies": ["connection_abstraction", "extend_config_tls_fields"],
    "user_story": "US1, US2",
    "verification": {
      "test_command": "make test",
      "expected_output": "All 0 tests passed",
      "build_command": "make build"
    }
  },
  {
    "name": "functional_tests_tls",
    "project": "",
    "layer": "infrastructure",
    "description": "Add functional tests: TLS-enabled server accepts encrypted connections and processes commands; plaintext mode unaffected by TLS feature existence; partial TLS config rejected at startup; failed TLS handshake does not crash server. Generate self-signed test certificates as test fixtures.",
    "files": ["src/functional_tests.zig", "test/fixtures/tls/cert.pem", "test/fixtures/tls/key.pem"],
    "tests": ["src/functional_tests.zig"],
    "dependencies": ["wire_tls_through_main"],
    "user_story": "US1, US2, US3, US4",
    "verification": {
      "test_command": "make test-functional",
      "expected_output": "All 0 tests passed",
      "build_command": "make build"
    }
  },
  {
    "name": "document_tls_setup",
    "project": "",
    "layer": "interfaces",
    "description": "Write ADR 0003 documenting the OpenSSL dependency decision. Update README with TLS configuration section. Update protocol reference with TLS notes.",
    "files": ["docs/ADR/0003-openssl-tls-dependency.md", "README.md"],
    "tests": [],
    "dependencies": ["wire_tls_through_main"],
    "user_story": "US5",
    "verification": {
      "test_command": "test -f docs/ADR/0003-openssl-tls-dependency.md",
      "expected_output": "exit 0"
    }
  }
]
```

## Test Plan

### Unit Tests

**Config TLS fields** (co-located in `config.zig`):
- Parse config with both `tls_cert` and `tls_key` under `[controller]` — fields populated correctly
- Parse config with neither TLS field — fields are null, backward compatible
- Parse config with only `tls_cert` — returns `ConfigError.InvalidValue`
- Parse config with only `tls_key` — returns `ConfigError.InvalidValue`
- `deinit` frees allocated TLS path strings without leak

**TlsContext** (co-located in `tls_context.zig`):
- Create context with valid cert/key — succeeds
- Create context with nonexistent cert path — returns file error
- Create context with invalid PEM — returns TLS init error
- `deinit` cleans up OpenSSL resources

**Connection abstraction** (co-located in `tcp_server.zig`):
- Plain Connection read/write via socketpair — identical to current behavior
- `write_response` works with Connection instead of raw Stream
- `handle_connection` works with Connection (existing tests adapted)
- Connection close releases resources

### Functional Tests

- Start ztick with TLS config + self-signed cert; connect via TLS client; send SET command; verify OK response over encrypted channel
- Start ztick without TLS config; connect via plaintext; verify identical behavior to current release
- Start ztick with only `tls_cert` set; verify startup exits with config error
- Connect to TLS-enabled server with plaintext; verify connection rejected; verify subsequent TLS connections succeed

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Zig 0.15.2 `@cImport` for OpenSSL headers has compilation issues | Med | P0 | Prototype the C import early (component 2). Fallback: use `extern fn` declarations instead of `@cImport`. OpenSSL C API is stable. | Implementer |
| System OpenSSL not available on CI or developer machines | Low | P1 | CI already runs on Linux (GitHub Actions). Add `apt-get install libssl-dev` to CI. Document in build prerequisites. | Implementer |
| Connection abstraction changes break existing tests | Med | P1 | Implement Connection as a drop-in replacement — plain variant wraps std.net.Stream with identical read/write/close semantics. Run `make test-all` after each change. | Implementer |
| OpenSSL linking increases binary size significantly | Low | P2 | Dynamic linking keeps binary small; static linking is opt-in. Plaintext-only builds skip linking entirely. | Implementer |
| TLS handshake blocking in connection_worker thread | Low | P1 | Each connection already runs in its own detached thread (`tcp_server.zig:91-104`). TLS handshake timeout can be set via OpenSSL's `SSL_set_timeout`. | Implementer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| Direct `std.net.Stream` usage in `handle_connection` (10 references) | Replaced by `Connection` abstraction | Replace all 10 occurrences |
| Duplicate Context structs in handle_connection tests (lines 940-953, 985-996) | Nearly identical test setup code | Extract shared test helper during Connection refactor |
| `build.zig.zon` zero-dependency comment | No longer accurate if OpenSSL is system-linked | Update or remove; document in ADR 0003 that `dependencies = .{}` still holds (system lib, not Zig package) |
