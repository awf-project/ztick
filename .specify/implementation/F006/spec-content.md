# F006: Add TLS Support to ztick Protocol

## Scope

### In Scope

- Extend `Config` to parse `tls_cert` and `tls_key` in the `[controller]` section
- Validate that both or neither TLS fields are set; error on partial configuration
- Abstract the stream interface in `tcp_server.zig` behind a `Connection` type
- Perform TLS handshake on accepted connections when TLS is configured
- Load PEM certificate and key files once at server startup
- Pass TLS configuration from `Config` through `main.zig` to `TcpServer`
- Document TLS configuration in protocol reference and user guide

### Out of Scope

- Mutual TLS (mTLS) client certificate authentication
- Certificate hot-reload via SIGHUP or filesystem watch
- STARTTLS upgrade on plaintext connections
- Custom cipher suite configuration
- OCSP stapling or certificate revocation checking

### Deferred

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| mTLS client authentication | Adds significant complexity; no current multi-tenant requirement | future |
| Certificate hot-reload (SIGHUP) | First implementation loads once at startup; reload requires signal handling infrastructure | future |
| Unix domain socket transport | Connection abstraction enables this but implementation is separate work | future |
| Custom cipher suite selection | TLS 1.3 defaults are secure; configurability adds attack surface | future |

---

## User Stories

### US1: Encrypted Protocol Traffic (P1 - Must Have)

**As a** ztick operator deploying beyond localhost,
**I want** to configure TLS on the ztick TCP server,
**So that** protocol traffic (commands, job identifiers, shell commands) is encrypted in transit.

**Why this priority**: Without encryption, all protocol traffic including shell commands (which may contain credentials) is visible to network observers. This is the core security gap the feature addresses.

**Acceptance Scenarios:**
1. **Given** a config with valid `tls_cert` and `tls_key` paths, **When** ztick starts, **Then** the server accepts TLS 1.3 connections on the configured listen address and completes handshakes using the provided certificate.
2. **Given** a running ztick with TLS enabled, **When** a TLS client sends `SET job1 1700000000000000000`, **Then** the command is processed identically to plaintext mode and the response `<request_id> OK` is returned over the encrypted channel.
3. **Given** a running ztick with TLS enabled, **When** a plaintext client connects, **Then** the TLS handshake fails, the connection is closed, and the server continues accepting new connections.

**Independent Test:** Start ztick with TLS config pointing to a self-signed cert/key pair. Connect with `openssl s_client` and send a SET command. Verify the OK response arrives over the TLS channel.

### US2: Backward-Compatible Plaintext Mode (P1 - Must Have)

**As a** ztick operator running on localhost,
**I want** ztick to continue working without any TLS configuration,
**So that** existing deployments are unaffected by the TLS feature.

**Why this priority**: Breaking existing deployments is unacceptable. Plaintext mode must remain the default when no TLS fields are configured.

**Acceptance Scenarios:**
1. **Given** a config file with no `tls_cert` or `tls_key` fields, **When** ztick starts, **Then** the server listens in plaintext mode exactly as before.
2. **Given** no config file at all (defaults applied), **When** ztick starts, **Then** the server listens in plaintext mode on `127.0.0.1:5678`.

**Independent Test:** Start ztick with the existing config (no TLS fields). Connect with `nc` or `socat` and send commands. Verify identical behavior to current release.

### US3: Configuration Validation for Partial TLS Settings (P2 - Should Have)

**As a** ztick operator,
**I want** ztick to reject a config where only one of `tls_cert` or `tls_key` is set,
**So that** I am alerted to misconfiguration at startup rather than encountering runtime failures.

**Why this priority**: Fail-fast validation prevents confusing runtime errors but is not required for TLS to function. A careful operator could always set both fields correctly.

**Acceptance Scenarios:**
1. **Given** a config with `tls_cert` set but `tls_key` missing, **When** ztick starts, **Then** it exits with `ConfigError.InvalidValue` before binding the listen socket.
2. **Given** a config with `tls_key` set but `tls_cert` missing, **When** ztick starts, **Then** it exits with `ConfigError.InvalidValue` before binding the listen socket.

**Independent Test:** Create a config with only `tls_cert` set. Start ztick and verify it exits with the expected error. Repeat with only `tls_key`.

### US4: Graceful TLS Handshake Failure Handling (P2 - Should Have)

**As a** ztick operator,
**I want** failed TLS handshakes to close only the offending connection without crashing the server,
**So that** one misbehaving or misconfigured client does not cause a denial of service.

**Why this priority**: Production resilience against malformed connections. Without this, a single bad client could take down the scheduler.

**Acceptance Scenarios:**
1. **Given** ztick running with TLS, **When** a client connects and sends garbage bytes instead of a TLS ClientHello, **Then** the server closes that connection and continues accepting new connections.
2. **Given** ztick running with TLS, **When** a client initiates a TLS handshake but disconnects mid-handshake, **Then** the server closes that connection and continues accepting new connections.

**Independent Test:** Connect with `nc` to the TLS-enabled port, send random bytes, disconnect. Verify subsequent TLS clients can still connect and issue commands.

### US5: TLS Setup Documentation (P3 - Nice to Have)

**As a** ztick operator new to TLS,
**I want** documentation explaining how to generate a self-signed certificate and configure ztick for TLS,
**So that** I can secure my deployment without external research.

**Why this priority**: Documentation improves adoption but is not a functional requirement. Operators familiar with TLS can configure it from the config key names alone.

**Acceptance Scenarios:**
1. **Given** the ztick documentation, **When** an operator follows the TLS setup guide, **Then** they can generate a self-signed cert and start ztick with TLS in under 5 minutes.

**Independent Test:** Follow the documented steps on a clean system. Verify ztick starts with TLS and accepts connections.

### Edge Cases

- What happens when the certificate file exists but is not valid PEM? Server must fail at startup with a clear error, not at first connection.
- What happens when the private key does not match the certificate? Server must fail at startup with a clear error.
- What happens when the certificate or key file path does not exist? Server must fail at startup with `ConfigError.InvalidValue` or a file-not-found error.
- What happens when file permissions prevent reading the key file? Server must fail at startup with a clear error.
- What happens when a TLS connection is established but the client sends a malformed protocol command? The TLS layer and protocol layer errors must be handled independently — TLS errors close the connection, protocol errors return `<request_id> ERROR`.
- What happens under concurrent TLS handshakes? The TLS context (cert/key) is loaded once and shared read-only; per-connection state is isolated.

---

## Requirements

### Functional Requirements

- **FR-001**: System MUST accept TLS 1.3 connections when both `tls_cert` and `tls_key` configuration keys are set to valid file paths
- **FR-002**: System MUST accept plaintext TCP connections when neither `tls_cert` nor `tls_key` is set (backward compatibility)
- **FR-003**: System MUST return `ConfigError.InvalidValue` at startup when exactly one of `tls_cert` or `tls_key` is set
- **FR-004**: System MUST load the certificate and private key from PEM files once at startup, not per-connection
- **FR-005**: System MUST close connections that fail the TLS handshake and continue accepting new connections
- **FR-006**: System MUST process all existing protocol commands (SET, REMOVE, QUERY, RULE SET, REMOVERULE, LISTRULES) identically over TLS and plaintext connections
- **FR-007**: System MUST validate that the certificate and key files are readable and well-formed at startup, failing with a clear error if not
- **FR-008**: System MUST expose a `Connection` abstraction in `tcp_server.zig` that `handle_connection()` uses instead of `std.net.Stream` directly [NEEDS CLARIFICATION: union type vs vtable — depends on Zig stdlib TLS API shape]

### Non-Functional Requirements

- **NFR-001**: TLS handshake latency MUST add less than 50ms to connection establishment time on localhost
- **NFR-002**: Certificate file contents and private key material MUST NOT appear in log output or error messages
- **NFR-003**: Server MUST remain available to new connections during and after a failed TLS handshake (no single-connection denial of service)
- **NFR-004**: Zero external dependencies MUST be maintained if `std.crypto.tls.Server` is sufficient; if an external TLS library is required, it MUST be added via `build.zig.zon` with a pinned hash [NEEDS CLARIFICATION: `std.crypto.tls.Server` availability in Zig 0.14 needs verification]

---

## Success Criteria

- **SC-001**: A TLS-enabled ztick instance accepts encrypted connections and processes all six protocol commands with identical results to plaintext mode
- **SC-002**: Existing deployments with no TLS configuration keys continue to function with zero changes required
- **SC-003**: Misconfigured TLS settings (partial config, bad cert, missing file) are caught at startup with a descriptive error within 1 second
- **SC-004**: A failed TLS handshake from a malicious or misconfigured client does not prevent subsequent clients from connecting
- **SC-005**: All existing tests continue to pass without modification (connection abstraction does not break plaintext code paths)

---

## Key Entities

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| Connection | Abstraction over transport layer, wrapping either a plain TCP stream or a TLS stream | read, write, close; transport type (plain or tls) |
| TlsContext | Server-side TLS state loaded once at startup from PEM files | certificate chain, private key; shared read-only across connections |
| Config (extended) | Application configuration with optional TLS fields | controller_tls_cert: ?[]const u8, controller_tls_key: ?[]const u8 |

---

## Assumptions

- Zig 0.14's `std.crypto.tls` module provides sufficient server-side TLS primitives, or a compatible Zig-native library (e.g., iguanaTLS) exists and builds with `zig 0.14.0+`
- PEM is the only certificate format supported (DER conversion is the operator's responsibility)
- The ztick protocol is low-frequency enough (scheduler control plane, not data plane) that per-connection TLS overhead is negligible
- Operators deploying beyond localhost have access to certificate generation tools (`openssl`, `mkcert`, or a CA)
- The three-thread architecture (controller, database, processor) does not change; TLS is handled entirely within the controller thread

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: medium
- **Estimation**: L

## Dependencies

- **Blocked by**: none
- **Unblocks**: none

## Clarifications

_Section populated during clarify step with resolved ambiguities._

## Notes

- `std.crypto.tls.Server` availability in Zig 0.14 must be verified before implementation begins. If server-side TLS is not in stdlib, the fallback path is adding a Zig-native TLS library via `build.zig.zon`. This is the first decision point in implementation planning.
- The `Connection` abstraction has value beyond TLS — it enables future Unix socket transport and improves testability of `handle_connection()` by allowing mock streams. Consider implementing the abstraction even if TLS itself is deferred due to stdlib limitations.
- The zero-external-dependencies constraint in `CLAUDE.md` (`build.zig.zon dependencies = .{}`) may need to be relaxed if `std.crypto.tls.Server` is insufficient. This is an architectural decision that should be documented as an ADR.
- Current `handle_connection()` uses `std.net.Stream` which has `read()` and `write()` methods. The `Connection` abstraction must match this interface to minimize changes in the protocol parsing and response writing code.
