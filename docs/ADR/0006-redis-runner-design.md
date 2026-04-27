# 0006: Redis Runner Design

**Status**: Accepted
**Date**: 2026-04-27
**Supersedes**: N/A
**Superseded by**: N/A

## Context

F020 adds a Redis runner to ztick so that scheduled jobs can publish to a Redis pub/sub channel, push onto a list, or set a key as their execution action. Five independent design decisions shaped the implementation in `src/infrastructure/runner/redis.zig` and the codec at `src/infrastructure/redis/resp.zig`:

1. Whether to use a third-party Redis client library or hand-roll the RESP2 codec.
2. Whether to support encrypted connections (`rediss://`).
3. Whether to pool broker connections across executions.
4. What "success" means when the broker writes back nothing meaningful (notably `PUBLISH` with zero subscribers).
5. What to put in the Redis command payload (the value/message body).

A sixth, persistence-layer decision is documented separately at the end: which on-disk discriminant byte identifies the new variant.

Each decision is documented separately below.

## Decision 1 — Hand-rolled RESP2 codec (no third-party library)

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Hand-roll RESP2 codec in stdlib** | Zero new Zig dependencies; NFR-004 compliant; RESP2 wire format is frozen, narrow, and small (~100 LOC for the subset ztick needs) | Byte-level bug risk; incremental cost for future protocol features (RESP3, transactions, scripting) |
| **Vendor a third-party Zig Redis client** | Less code to write | No maintained Zig 0.15.2-compatible Redis client exists; breaches NFR-004 and ADR-0002 |

### Decision

Encode and decode RESP2 frames by hand in `src/infrastructure/redis/resp.zig`. The codec covers the subset ztick needs: arrays of bulk strings on the encode side (used to send `AUTH`, `SELECT`, `PUBLISH`, `RPUSH`, `LPUSH`, `SET`); integers (`:`), simple strings (`+`), bulk strings (`$`), null bulks (`$-1`), and errors (`-`) on the decode side, plus arrays (`*`) for completeness. Encoders are byte-precise and unit-tested against pre-computed literals (e.g., `*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n`).

### Consequences

**What becomes easier:**
- No new entries in `build.zig.zon`; NFR-004 remains unbroken.
- The implemented subset is fully covered by encoder and decoder tests with pre-computed wire literals.

**What becomes harder:**
- Byte-level bugs are possible; the test suite is the primary guard.
- Adding protocol features (RESP3, pipelining, transactions, pub/sub subscriber-side, scripting) requires incremental hand-implementation rather than a library upgrade.

---

## Decision 2 — Plaintext TCP only; `rediss://` explicitly rejected

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Plaintext TCP only; reject `rediss://`** | Minimal scope; no additional cert/CA configuration; sidecar TLS (`stunnel`) is industry-standard for this case | Production deployments with regulatory in-transit encryption requirements need an external proxy |
| **REDISS via existing `tls_context.zig`** | Single binary handles encrypted broker connections | Outbound TLS support touches the same surface as listener TLS; should be designed as one cross-cutting track rather than per-runner |

### Decision

`parse_url` rejects `rediss://` schemes (and any non-`redis://` scheme) with `error.InvalidScheme`. The limitation is documented in the user guide alongside the AMQP equivalent. Production environments requiring encryption should terminate TLS via a sidecar (`stunnel`, Nginx stream proxy, or Redis-side TLS offload via Redis 6+ TLS) rather than within ztick.

### Consequences

**What becomes easier:**
- No new configuration keys for client certificates or CA bundles.
- The integration test stack runs over plaintext without extra setup.

**What becomes harder:**
- Users with in-transit encryption requirements must operate an external TLS proxy until a follow-up ADR adds outbound TLS support across all broker runners.

---

## Decision 3 — Per-execution connect / handshake / command / close (no connection pool)

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Per-execution connection lifecycle** | Simple state machine; no idle reaper or broker-close detection needed; Redis handshake on localhost is sub-millisecond | Opens a new TCP connection on every rule firing |
| **Per-URL connection pool** | Amortises handshake cost across executions | Requires connection-state tracking, idle reaper, broker-side close detection, per-URL cache; no measured contention pressure justifies the complexity |

### Decision

Open a fresh TCP connection on every execution. Send optional `AUTH` (when credentials are present), then optional `SELECT <db>` (when db != 0), then the configured command, then close. Socket-level `SO_RCVTIMEO` and `SO_SNDTIMEO` are set to 30 seconds to cap exposure to slow or unresponsive brokers — matching the AMQP and HTTP runners.

### Consequences

**What becomes easier:**
- Connection state is trivially correct: each execution is independent.
- The `execute()` surface does not change if pooling is added later.

**What becomes harder:**
- A slow broker can occupy a processor thread for up to 30 seconds per execution.
- At high rule-firing rates against a remote broker, handshake overhead may become measurable; pooling can be added when concrete contention evidence exists.

---

## Decision 4 — Fire-and-forget success semantics; PUBLISH-with-zero-subscribers is success

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **`success = true` when RESP returned without an error reply** | Lower round-trip cost; matches `redis-cli` defaults; no false negatives for fan-out use cases that tolerate zero subscribers | `success = true` for `PUBLISH` does not imply any subscriber received the message |
| **Treat `PUBLISH 0` as failure** | Surfaces topology misconfiguration (subscriber not yet running) | Race-condition prone; punishes legitimate fan-out patterns where bursts of publishes precede a subscriber attaching; no consumer has expressed drop-detection requirements |

### Decision

`success = true` reflects two conditions: the RESP reply was not an error (`-...`) frame, and (for `PUBLISH`/`RPUSH`/`LPUSH`/`SET`) the reply matched the expected shape (integer for `PUBLISH`/`RPUSH`/`LPUSH`; `+OK` for `SET`/`AUTH`/`SELECT`). `PUBLISH` returning `:0\r\n` (zero subscribers) is therefore `success = true` in v1. The distinction is documented in the user guide's Troubleshooting section.

### Consequences

**What becomes easier:**
- Publish latency is one round-trip per command (no extra confirm step).
- Channel state machine has no confirm mode; simpler to reason about and test.

**What becomes harder:**
- Misconfigured topology (no subscribers, wrong channel name) causes silent drop on `PUBLISH`.
- Users who need delivery guarantees must use `RPUSH`/`LPUSH` (which return list lengths) or implement a follow-up `LRANGE`/`LLEN` check externally.

---

## Decision 5 — Command payload is the job identifier; no JSON envelope

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Job identifier as the bulk-string body** | Minimal; no format lock-in before consumers exist; consumers can look up full context via TCP `GET <job_id>` | Consumers needing richer context must make a secondary lookup |
| **JSON envelope `{job_id, execution_ts, rule_id}`** | Richer payload; no secondary lookup needed | Locks in a wire format before any consumer has expressed requirements; schema change is a breaking wire-format change |

### Decision

The command's payload bulk string is `request.job_identifier`. For `PUBLISH <channel>`, the message is the job identifier. For `RPUSH <key>` / `LPUSH <key>`, the appended element is the job identifier. For `SET <key>`, the value is the job identifier. No structured envelope is included. When richer payloads are needed, they can be added additively — via a versioned structured body, Redis Streams entries, or hash fields — without breaking consumers reading today's format.

### Consequences

**What becomes easier:**
- No wire-format breakage risk: today's consumers receive the job ID and can look up context independently.
- Future payload evolution is additive; no existing consumer needs to change.

**What becomes harder:**
- Consumers needing timestamp, rule ID, or status must perform a secondary TCP `GET <job_id>` against ztick.

---

## Persistence discriminant

The Redis runner's persisted shape uses **discriminant byte `5`**, not `2` as F020's spec note (line 169) states.

### Why `5`, not `2`

By the time F020 lands, the existing on-disk discriminants (in `src/infrastructure/persistence/encoder.zig`) are:

| Byte | Variant | Introduced |
|------|---------|------------|
| `0` | `shell` | initial |
| `1` | `amqp` | F019 |
| `2` | `direct` | F019 cleanup (the byte F020's spec proposed for redis) |
| `3` | `awf` | (existing) |
| `4` | `http` | (existing) |
| `5` | `redis` | **F020 (this ADR)** |

Reusing `2` would silently corrupt every existing user's logfile because the decoder would interpret persisted `direct` rules as malformed `redis` rules. Renumbering existing variants is forbidden by both the F020 spec ("do not renumber existing variants") and CLAUDE.md persistence guidance.

### Decision

Use the next available byte (`5`) for the redis variant. Document the deviation from the spec note here and inline at the encode/decode switch sites in `encoder.zig`. Round-trip tests assert the discriminant byte equals `5`.

### Consequences

**What becomes easier:**
- Existing logfiles continue to load unchanged; users upgrading across F020 see no persistence regression.
- Future variants extend the same monotonically-increasing numbering scheme.

**What becomes harder:**
- The F020 spec text and this ADR diverge on the literal byte value; readers reconciling spec to implementation must read both.

---

## Constitution Compliance

| Principle | Status | Justification |
|-----------|--------|---------------|
| Zero external Zig dependencies (NFR-004) | Compliant | Hand-rolled RESP2 codec; `build.zig.zon dependencies` unchanged |
| Hexagonal Architecture (ADR-0001) | Compliant | All Redis wire logic isolated in `src/infrastructure/runner/redis.zig` and `src/infrastructure/redis/resp.zig`; domain layer adds one variant only; application layer untouched |
| Stdlib-only (ADR-0002) | Compliant | Only `std.net`, `std.posix`, `std.io`, and `std.mem` used; no C interop required for plaintext Redis |
| Minimal Abstraction | Compliant | Single `execute()` entry point; no speculative interfaces for pooling, RESP3, or structured payloads |
| Per-execution outbound TCP (ADR-0005 precedent) | Compliant | Connect → optional AUTH → optional SELECT → command → close; identical lifecycle to AMQP and HTTP runners |
| Plaintext-only outbound TCP (ADR-0005 precedent) | Compliant | `rediss://` rejected at parse time; sidecar TLS is the documented path |

## References

- **Spec**: `.specify/implementation/F020/spec-content.md`
- **Plan**: `.specify/implementation/F020/plan.md`
- **ADR-0001**: `docs/ADR/0001-hexagonal-architecture.md` (hexagonal architecture)
- **ADR-0002**: `docs/ADR/0002-zig-language-choice.md` (Zig stdlib-only, zero Zig package dependencies)
- **ADR-0005**: `docs/ADR/0005-amqp-runner-design.md` (AMQP runner design — direct precedent for the per-execution-connect, plaintext-only, hand-rolled-codec, fire-and-forget pattern reused here)
- **RESP2 specification**: https://redis.io/docs/latest/develop/reference/protocol-spec/
