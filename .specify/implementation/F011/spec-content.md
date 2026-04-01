# F011: Add Client Authentication to ztick Protocol

## Scope

### In Scope

- Token-based AUTH handshake as the first command on new TCP connections
- Namespace-scoped authorization enforcing prefix-based access control on all commands
- Auth file parsing (TOML format) with token name, secret, and namespace
- Config extension to reference an optional auth file
- Constant-time secret comparison to prevent timing attacks
- Backward compatibility: no auth required when `auth_file` is unset

### Out of Scope

- Per-command granularity (read-only vs read-write tokens)
- Secret hashing at rest (argon2/bcrypt)
- Hot-reload of auth file via SIGHUP
- Role-based access control or multi-level permissions
- Token rotation or expiration

### Deferred

| Item | Rationale | Follow-up |
|------|-----------|-----------|
| Secret hashing at rest | Plaintext acceptable for v1 with file permission restrictions; hashing adds complexity and a crypto dependency decision | future |
| Per-command ACLs (read-only tokens) | v1 scope is identity + namespace; granular permissions require a permission model design | future |
| SIGHUP-based auth file reload | Restart-on-change is acceptable for v1; hot-reload requires file watching and atomic store swap | future |
| Token expiration / rotation | Operational concern; v1 relies on manual file edits and restart | future |

---

## User Stories

### US1: Authenticate Connecting Clients (P1 - Must Have)

**As a** server operator,
**I want** connecting clients to prove their identity with a secret token before issuing commands,
**So that** only authorized clients can interact with the scheduler.

**Why this priority**: Without authentication, any network-reachable client can mutate scheduler state. This is the foundational gate that all other authorization depends on.

**Acceptance Scenarios:**
1. **Given** auth is enabled and a client connects, **When** the client sends `AUTH sk_deploy_a1b2c3d4e5f6
` with a valid token, **Then** the server responds `OK
` and accepts subsequent commands.
2. **Given** auth is enabled and a client connects, **When** the client sends `AUTH invalid_secret
`, **Then** the server responds `ERROR
` and closes the connection.
3. **Given** auth is enabled and a client connects, **When** the client sends a non-AUTH command as the first message, **Then** the server responds `ERROR
` and closes the connection.
4. **Given** auth is enabled and a client connects, **When** the client sends no data within the auth timeout period, **Then** the server closes the connection.

**Independent Test:** Connect via TCP, send `AUTH <valid-token>
`, verify `OK
` response, then send a `SET` command and verify it succeeds.

### US2: Restrict Commands to Client Namespace (P2 - Should Have)

**As a** server operator running multiple services against one ztick instance,
**I want** each client's commands restricted to a namespace prefix,
**So that** one service cannot read or mutate another service's jobs and rules.

**Why this priority**: Authentication alone (US1) gates access but does not isolate tenants. Namespace enforcement delivers multi-tenant safety, the primary motivation for this feature.

**Acceptance Scenarios:**
1. **Given** a client authenticated with namespace `deploy.`, **When** the client sends `SET deploy.release.1 2026-04-01 12:00:00
`, **Then** the server accepts the command and responds `OK`.
2. **Given** a client authenticated with namespace `deploy.`, **When** the client sends `SET backup.daily 2026-04-01 12:00:00
`, **Then** the server responds `ERROR
` and does not execute the command.
3. **Given** a client authenticated with namespace `*`, **When** the client sends any valid command targeting any identifier, **Then** the server accepts the command.
4. **Given** a client authenticated with namespace `deploy.`, **When** the client sends `QUERY *
`, **Then** the response contains only jobs whose identifiers start with `deploy.`.

**Independent Test:** Authenticate with a `deploy.` namespace token, attempt `SET backup.x ...`, verify `ERROR`. Then `SET deploy.x ...`, verify `OK`.

### US3: Backward-Compatible No-Auth Mode (P1 - Must Have)

**As a** server operator with an existing deployment,
**I want** authentication to be entirely optional,
**So that** upgrading ztick does not break existing setups that do not need auth.

**Why this priority**: Breaking backward compatibility on upgrade would block adoption. Existing single-tenant deployments must continue to work without configuration changes.

**Acceptance Scenarios:**
1. **Given** no `auth_file` key in the config, **When** a client connects and sends commands without AUTH, **Then** all commands are accepted as before.
2. **Given** the config file has no `[controller]` section, **When** ztick starts, **Then** it runs without authentication.

**Independent Test:** Start ztick with default config (no `auth_file`), connect, send `SET test.job 2026-04-01 12:00:00
`, verify `OK` without any AUTH step.

### US4: RULE SET Namespace Enforcement (P2 - Should Have)

**As a** server operator,
**I want** rule creation restricted so that a client can only create rules targeting jobs within its namespace,
**So that** one tenant cannot schedule execution for another tenant's jobs.

**Why this priority**: Rules trigger job execution. Without rule namespace enforcement, a client could create rules that affect jobs outside its namespace, bypassing the command-level restriction.

**Acceptance Scenarios:**
1. **Given** a client authenticated with namespace `deploy.`, **When** the client sends `RULE SET rule.deploy deploy. shell echo ok
`, **Then** the server accepts the rule.
2. **Given** a client authenticated with namespace `deploy.`, **When** the client sends `RULE SET rule.backup backup. shell echo ok
`, **Then** the server responds `ERROR
`.
3. **Given** a client authenticated with namespace `deploy.`, **When** the client sends `RULE SET deploy.myrule deploy. shell echo ok
` where both rule ID and pattern start with `deploy.`, **Then** the server accepts the rule.

**Independent Test:** Authenticate with `deploy.` namespace, attempt `RULE SET x backup. shell echo`, verify `ERROR`. Then `RULE SET deploy.r deploy. shell echo`, verify `OK`.

### US5: Auth File Configuration and Parsing (P1 - Must Have)

**As a** server operator,
**I want** to define tokens, secrets, and namespaces in a TOML file referenced from the main config,
**So that** I can manage client credentials separately from runtime configuration.

**Why this priority**: The auth file is the data source for US1 and US2. Without it, there is no way to define tokens.

**Acceptance Scenarios:**
1. **Given** a valid auth file with two token sections, **When** ztick starts with `auth_file` pointing to it, **Then** both tokens are loaded and usable for authentication.
2. **Given** an auth file with duplicate secrets across two tokens, **When** ztick starts, **Then** startup fails with a validation error.
3. **Given** an auth file with a token section missing the `secret` key, **When** ztick starts, **Then** startup fails with a parse error.
4. **Given** `auth_file` points to a nonexistent path, **When** ztick starts, **Then** startup fails with a file-not-found error.

**Independent Test:** Create an auth file with one valid token, configure `auth_file`, start ztick, authenticate with that token, verify `OK`.

### Edge Cases

- What happens when a client sends an empty `AUTH 
` with no token? Server responds `ERROR
` and closes connection.
- What happens when the auth file contains zero token sections? Server starts with auth enabled but no valid tokens; all connections are rejected.
- How does the system handle a token whose namespace is an empty string? Rejected at parse time; empty namespaces are invalid.
- What happens when a client sends a second `AUTH` after successful authentication? Treated as an unknown command; responds `ERROR
`.
- What is the behavior when the auth file has a `namespace = "*"` and the client sends `QUERY *`? All results are returned unfiltered.
- What happens when `REMOVE` targets an identifier outside the client namespace? Denied with `ERROR
`.

---

## Requirements

### Functional Requirements

- **FR-001**: System MUST require `AUTH <token>
` as the first message on every new connection when `auth_file` is configured.
- **FR-002**: System MUST respond `OK
` for valid tokens and `ERROR
` for invalid tokens, closing the connection on failure.
- **FR-003**: System MUST accept all commands without authentication when `auth_file` is not configured (backward compatibility).
- **FR-004**: System MUST enforce namespace prefix matching on every command's target identifier after authentication.
- **FR-005**: System MUST treat `namespace = "*"` as granting access to all identifiers.
- **FR-006**: System MUST filter QUERY results to only include entries matching the client's namespace prefix.
- **FR-007**: System MUST enforce namespace on both the rule identifier and the rule pattern for `RULE SET` commands.
- **FR-008**: System MUST use constant-time comparison for secret matching to prevent timing attacks.
- **FR-009**: System MUST reject auth files with duplicate secrets, empty namespaces, or missing required fields at startup.
- **FR-010**: System MUST close connections that do not complete AUTH within 5 seconds when auth is enabled.
- **FR-011**: System MUST NOT retain the secret in the connection-scoped identity after successful authentication.

### Non-Functional Requirements

- **NFR-001**: Auth handshake MUST complete in under 1ms for a valid token (excluding network latency).
- **NFR-002**: Secrets MUST NOT appear in log output, error messages, or debug traces.
- **NFR-003**: Per-command namespace check MUST add no more than 1μs overhead (single prefix comparison).
- **NFR-004**: Token store MUST support at least 1000 tokens without measurable startup delay (<100ms parse time).
- **NFR-005**: System MUST document that TLS (F006) is recommended when using auth, as tokens travel in cleartext without it.

---

## Success Criteria

- **SC-001**: Connections without valid AUTH are rejected within 100ms when auth is enabled.
- **SC-002**: Commands targeting identifiers outside the client namespace are denied with zero side effects on scheduler state.
- **SC-003**: Existing deployments without `auth_file` configured experience zero behavioral change after upgrade.
- **SC-004**: All functional tests pass covering: valid auth, invalid auth, namespace allow, namespace deny, wildcard namespace, QUERY filtering, RULE SET namespace enforcement.
- **SC-005**: Constant-time comparison is verified by test asserting equal execution path regardless of secret prefix match length.

---

## Key Entities

| Entity | Description | Key Attributes |
|--------|-------------|----------------|
| Token | A named credential granting scoped access to the scheduler | `name: []const u8`, `secret: []const u8`, `namespace: []const u8` |
| ClientIdentity | The resolved identity for an authenticated connection (secret-free) | `name: []const u8`, `namespace: []const u8` |
| TokenStore | Application service that loads tokens and performs authentication and authorization checks | `tokens: []Token`, `authenticate(secret) ?ClientIdentity`, `is_authorized(identity, identifier) bool` |

---

## Assumptions

- The auth file is read once at startup; changes require a server restart.
- Token secrets are stored as plaintext in the auth file; file system permissions are the operator's responsibility to set.
- A single namespace prefix per token is sufficient for v1; compound namespaces (multiple prefixes) are not needed.
- The AUTH command uses the same line-based text protocol as all other commands (newline-terminated).
- Namespace prefixes always end with a period (e.g., `deploy.`) to prevent partial-word matches (e.g., `deploy` matching `deployer.`).
- TLS (F006) is available but not required; operators accept the risk of cleartext tokens without TLS.

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

- TLS support (F006) is strongly recommended before deploying auth in production. Without TLS, tokens are transmitted in cleartext over TCP. Document this prominently in user-facing configuration docs.
- The `std.crypto.utils.timingSafeEql` function in Zig stdlib is the preferred implementation for constant-time comparison if available; otherwise implement a byte-by-byte XOR accumulator.
- The auth file parser should reuse the TOML section-parsing pattern established in `config.zig` for consistency.
- QUERY namespace filtering must happen at result serialization time in the connection handler, not in the scheduler, to keep the scheduler auth-unaware and maintain hexagonal layering.
- The `ClientIdentity` struct deliberately excludes the secret to minimize the window where secrets exist in memory. After `authenticate()` resolves, only name and namespace are retained.
