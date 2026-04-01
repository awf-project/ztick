# Implementation Plan: F011

## Summary

Add token-based client authentication to ztick's TCP protocol with namespace-scoped authorization. AUTH handshake is enforced as the first command on new connections when `auth_file` is configured, with backward-compatible no-auth mode when unset. Implementation follows the F006 TLS pattern: optional config field, dedicated infrastructure adapter, connection-scoped state.

## Constitution Compliance

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal Architecture | COMPLIANT | Token/ClientIdentity in domain, TokenStore in application, auth file parser + AUTH handshake in infrastructure, config extension in interfaces. Strict inward dependency flow via barrel exports. |
| TDD Methodology | COMPLIANT | Co-located unit tests in each new file, functional E2E tests in functional_tests.zig. Every public function tested. |
| Zig Idioms | COMPLIANT | Error unions for fallible parsing, `try`/`errdefer` cleanup, `std.log` for auth events, `zig fmt` enforced. No `@panic` in library code. |
| Minimal Abstraction | COMPLIANT | Plain structs (Token, ClientIdentity), no interfaces — single TokenStore implementation. Tagged union not used for AUTH (handled at connection level, not as Instruction variant). |

Constitution: Derived from `.specify/memory/constitution.md`

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.15.2 |
| Framework | None (custom TCP server, custom TOML parser) |
| Architecture | Hexagonal with 4 strict layers (domain → application → infrastructure → interfaces) |
| Key patterns | Optional config fields (`?[]const u8 = null`), set-before-spawn initialization, connection-scoped state, `StringHashMapUnmanaged` storage, `std.mem.startsWith` prefix matching, barrel exports |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | Where AUTH is handled in the connection lifecycle | AUTH handshake in `handle_connection()` before the main command parse loop (line 210), not as an Instruction variant dispatched to the scheduler | `tcp_server.zig:189-291` — handle_connection sets up response channel then enters parse loop; AUTH must gate entry. `instruction.zig:4-27` — Instruction union has 7 command variants; AUTH is a connection concern, not a scheduler concern. |
| A2 | How TokenStore indexes tokens for O(1) lookup | Index by secret (not name) using `StringHashMapUnmanaged(ClientIdentity)` since `authenticate(secret)` is the hot path | `rule_storage.zig:7-9` — RuleStorage uses `StringHashMapUnmanaged(Rule)` indexed by identifier; TokenStore follows same pattern but keyed by secret for direct lookup. |
| A3 | How QUERY namespace filtering is implemented | Filter in `handle_connection()` at response serialization time, intersecting the QUERY pattern with the client namespace prefix | `tcp_server.zig:256-263` — response body is already received and written in handle_connection; filtering here keeps scheduler auth-unaware per spec note. `query_handler.zig:50-66` — QUERY uses `get_by_prefix(pattern)` which returns all matching jobs; connection handler can re-filter. |
| A4 | `std.crypto.utils.timingSafeEql` API name in Zig 0.15.2 | The correct API is `std.crypto.timing_safe.eql` (not `std.crypto.utils.timingSafeEql`) | Verified via `/usr/lib/zig/std/crypto/` — `timing_safe.eql` used throughout stdlib (aegis.zig, aes_gcm.zig, tls/Client.zig). `std.crypto.utils` does not exist in 0.15.2. |
| A5 | How TokenStore is passed to TcpServer/connection_worker | Add `token_store` field to `ControllerContext` and pass through `connection_worker` to `handle_connection`, following the `tls_context` pattern | `main.zig:113-121` — ControllerContext carries `tls_context: ?*TlsContext`; add `token_store: ?*TokenStore` alongside it. `main.zig:142-151` — `run_controller` passes context fields to `TcpServer.init`; same pattern. |
| A6 | Auth file format uses same custom TOML parser or separate parser | Separate dedicated parser in infrastructure layer — auth file has different section semantics (`[token.<name>]` sections) than main config | `config.zig:76-163` — main config parser is monolithic with hardcoded section names; auth file needs `[token.*]` dynamic section parsing which doesn't fit the existing pattern. |
| A7 | Namespace enforcement on RULE SET checks both rule ID and pattern | Both the rule identifier and the rule pattern must start with the client's namespace prefix (per FR-007, US4 scenarios 2-3) | Spec US4 acceptance scenarios explicitly test both rule ID prefix and pattern prefix. |

## Approach Comparison

| Criteria | Approach A: Connection-scoped AUTH | Approach B: AUTH as Instruction variant | Approach C: Middleware layer |
|----------|-----------------------------------|----------------------------------------|------------------------------|
| Description | AUTH handled in handle_connection before command loop; ClientIdentity stored as local variable | Add AUTH to Instruction union, dispatch through scheduler like other commands | Create auth middleware wrapping Connection with pre/post hooks |
| Files touched | 6 (2 new + 4 modified) | 8+ (touches scheduler, query_handler, persistence encoder, all Instruction switch sites) | 7+ (new middleware abstraction + all existing files) |
| New abstractions | 2 (Token struct, TokenStore) | 2 (same + Instruction variant) | 3 (same + Middleware trait) |
| Risk level | Low | High | Med |
| Reversibility | Easy | Hard (Instruction changes ripple) | Med |

**Selected: Approach A**
**Rationale:** AUTH is a connection-level concern (like TLS handshake), not a scheduler command. Adding AUTH to the Instruction union would require updating every exhaustive switch across 6+ files (query_handler, persistence encoder, tcp_server build/free, dump) for a variant that never reaches the scheduler. The spec explicitly states AUTH is handled before command dispatch. The F006 TLS precedent validates connection-scoped state without scheduler involvement.
**Trade-off accepted:** Namespace enforcement logic lives in tcp_server.zig rather than being centralized in a dedicated authorization module, but this keeps the implementation minimal and avoids premature abstraction (one enforcement site).

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| TokenStore keyed by secret, not by name | `authenticate(secret)` is the only lookup path; keying by name would require a full scan | HashMap keyed by name with linear scan for secret matching |
| AUTH timeout via read deadline on connection | FR-010 requires 5s timeout; connection read already blocks in handle_connection | Separate timer thread per connection (over-engineered) |
| ClientIdentity as plain struct, not stored in Request | Secret excluded per FR-011; identity is connection-local state used only for namespace checks | Extending Request struct with optional identity field (leaks auth into scheduler) |
| `std.crypto.timing_safe.eql` for secret comparison | Stdlib constant-time comparison, verified available in Zig 0.15.2; requires fixed-size arrays | Custom XOR accumulator (unnecessary when stdlib provides it) |
| Auth file parser as separate infrastructure module | Auth TOML has dynamic `[token.<name>]` sections unlike main config's fixed sections; mixing them would bloat config.zig | Extending existing config.zig parser (different section semantics) |
| No new ADR needed | No new external dependencies; uses only Zig stdlib (`std.crypto.timing_safe`) | Writing ADR-0005 (no dependency decision to document) |

## Components

```json
[
  {
    "name": "domain_auth_types",
    "project": "",
    "layer": "domain",
    "description": "Token and ClientIdentity structs representing authentication credentials and resolved connection identity",
    "files": ["src/domain/auth.zig", "src/domain.zig"],
    "tests": ["src/domain/auth.zig"],
    "dependencies": [],
    "user_story": "US1, US5",
    "verification": {
      "test_command": "zig build test-domain --summary all 2>&1 | tail -5",
      "expected_output": "Build Summary: 1/1 steps succeeded",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "token_store",
    "project": "",
    "layer": "application",
    "description": "TokenStore service that loads tokens from parsed auth data, authenticates secrets via constant-time comparison, and checks namespace authorization",
    "files": ["src/application/token_store.zig", "src/application.zig"],
    "tests": ["src/application/token_store.zig"],
    "dependencies": ["domain_auth_types"],
    "user_story": "US1, US2, US5",
    "verification": {
      "test_command": "zig build test-application --summary all 2>&1 | tail -5",
      "expected_output": "Build Summary: 1/1 steps succeeded",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "auth_file_parser",
    "project": "",
    "layer": "infrastructure",
    "description": "TOML auth file parser that reads [token.<name>] sections with secret and namespace fields, validates constraints (no duplicate secrets, no empty namespaces), and returns Token array",
    "files": ["src/infrastructure/auth.zig", "src/infrastructure.zig"],
    "tests": ["src/infrastructure/auth.zig"],
    "dependencies": ["domain_auth_types"],
    "user_story": "US5",
    "verification": {
      "test_command": "zig build test-infrastructure --summary all 2>&1 | tail -5",
      "expected_output": "Build Summary: 1/1 steps succeeded",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "config_and_wiring",
    "project": "",
    "layer": "interfaces",
    "description": "Extend Config with controller_auth_file optional field, parse in [controller] section, wire TokenStore creation in main.zig and pass through ControllerContext to TcpServer",
    "files": ["src/interfaces/config.zig", "src/main.zig"],
    "tests": ["src/interfaces/config.zig", "src/main.zig"],
    "dependencies": ["token_store", "auth_file_parser"],
    "user_story": "US3, US5",
    "verification": {
      "test_command": "zig build test-interfaces --summary all 2>&1 | tail -5",
      "expected_output": "Build Summary: 1/1 steps succeeded",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "auth_handshake_and_namespace",
    "project": "",
    "layer": "infrastructure",
    "description": "AUTH handshake in handle_connection before command loop with 5s timeout, namespace enforcement on all commands (SET, GET, REMOVE, RULE SET, QUERY filtering), connection closure on auth failure",
    "files": ["src/infrastructure/tcp_server.zig"],
    "tests": ["src/infrastructure/tcp_server.zig"],
    "dependencies": ["token_store", "domain_auth_types", "config_and_wiring"],
    "user_story": "US1, US2, US4",
    "verification": {
      "test_command": "zig build test-infrastructure --summary all 2>&1 | tail -5",
      "expected_output": "Build Summary: 1/1 steps succeeded",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "functional_tests",
    "project": "",
    "layer": "infrastructure",
    "description": "End-to-end functional tests: valid/invalid AUTH, namespace allow/deny, wildcard namespace, QUERY filtering, RULE SET namespace enforcement, backward compatibility (no auth_file), auth timeout",
    "files": ["src/functional_tests.zig"],
    "tests": ["src/functional_tests.zig"],
    "dependencies": ["auth_handshake_and_namespace", "config_and_wiring"],
    "user_story": "US1, US2, US3, US4, US5",
    "verification": {
      "test_command": "zig build test-functional --summary all 2>&1 | tail -5",
      "expected_output": "Build Summary: 1/1 steps succeeded",
      "build_command": "make build && zig build test-functional --summary all"
    }
  }
]
```

## Test Plan

```yaml
unit_tests:
  scope: "Per component, co-located in source files"
  naming: "test \"descriptive behavior name\""
  requirements:
    domain_auth_types:
      - Token struct construction with name, secret, namespace
      - ClientIdentity struct construction without secret (FR-011)
    token_store:
      - authenticate returns ClientIdentity for valid secret
      - authenticate returns null for invalid secret
      - authenticate uses constant-time comparison (equal execution path)
      - is_authorized returns true when identifier starts with namespace
      - is_authorized returns false when identifier does not start with namespace
      - is_authorized returns true for wildcard namespace "*"
      - initialization rejects duplicate secrets (FR-009)
      - initialization rejects empty namespaces (FR-009)
    auth_file_parser:
      - parse valid auth file with two token sections
      - parse rejects missing secret key in token section
      - parse rejects duplicate secrets across sections
      - parse rejects empty namespace value
      - parse rejects auth file with zero token sections (no error, but empty)
      - parse handles namespace = "*" correctly
    config:
      - auth_file defaults to null when key absent
      - auth_file parsed from [controller] section
      - auth_file key accepted alongside tls_cert/tls_key
    auth_handshake:
      - AUTH with valid token returns OK and allows commands (via socketpair)
      - AUTH with invalid token returns ERROR and closes connection
      - Non-AUTH first command returns ERROR and closes connection
      - Namespace-scoped command within namespace succeeds
      - Namespace-scoped command outside namespace returns ERROR
      - QUERY results filtered to client namespace
      - RULE SET rejected when pattern outside namespace

functional_tests:
  scope: "End-to-end with TestServer helper"
  naming: "test \"F011: descriptive scenario\""
  requirements:
    - Valid AUTH followed by SET command succeeds
    - Invalid AUTH closes connection
    - No auth_file config allows commands without AUTH (backward compat)
    - Namespace-scoped SET within namespace succeeds, outside fails
    - Wildcard namespace allows all commands
    - QUERY returns only namespace-matching results
```

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| `std.crypto.timing_safe.eql` requires compile-time known array length; secrets are variable-length `[]const u8` | High | P1 | Pad/hash secrets to fixed-length at load time (e.g., SHA-256 both stored and provided secret, compare the 32-byte digests), or implement byte-by-byte XOR accumulator for variable-length comparison | Developer |
| Auth timeout (FR-010, 5s) requires setting read deadline on socket; `std.net.Stream` may not expose `SO_RCVTIMEO` directly | Med | P1 | Use `std.posix.setsockopt` with `SO_RCVTIMEO` on the raw fd before entering AUTH read, or use non-blocking read with poll/timeout | Developer |
| QUERY namespace filtering in handle_connection duplicates body parsing logic | Low | P2 | Keep filtering simple: re-query with intersected prefix (namespace + query pattern) rather than parsing the response body string | Developer |
| Auth file path resolution relative to config file vs CWD | Med | P1 | Follow existing config.zig pattern: paths are relative to CWD (same as `logfile_path`, `tls_cert`); document this behavior | Developer |
| Exhaustive Instruction switch sites need updating if AUTH were added as variant (mitigated by Approach A) | Low | P0 | AUTH is NOT an Instruction variant — no switch site changes needed. This risk is eliminated by the selected approach. | N/A |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| AMQP runner scaffolding | Dead code across 6+ files (runner.zig, tcp_server.zig, encoder, query_handler, dump) returning `error.UnsupportedRunner` | OUT OF SCOPE — separate cleanup PR. Does not block F011. |
| Config TOML parsing repetition | Adding `auth_file` will copy the string allocation pattern a 7th time | OUT OF SCOPE — extract helpers in separate refactor if desired. |

## Implementation Order

1. **domain_auth_types** — Pure data structs, no dependencies
2. **token_store** — Application logic with constant-time comparison
3. **auth_file_parser** — TOML parsing for `[token.<name>]` sections
4. **config_and_wiring** — Config field + main.zig integration
5. **auth_handshake_and_namespace** — TCP server AUTH flow + namespace checks
6. **functional_tests** — E2E validation

## Test Fixtures

Create `test/fixtures/auth/` directory with:
- `valid.toml` — Two tokens with distinct secrets and namespaces
- `wildcard.toml` — Token with `namespace = "*"`
- `duplicate_secret.toml` — Two tokens sharing a secret (invalid)
- `missing_secret.toml` — Token section without `secret` key (invalid)
- `empty_namespace.toml` — Token with `namespace = ""` (invalid)
