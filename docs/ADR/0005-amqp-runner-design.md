---
title: "0005: AMQP Runner Design"
---

**Status**: Accepted
**Date**: 2026-04-26
**Supersedes**: N/A
**Superseded by**: N/A

## Context

F019 adds an AMQP 0-9-1 runner to ztick so that scheduled jobs can publish messages to a broker (e.g., RabbitMQ) as their execution action. Five independent design decisions shaped the implementation in `src/infrastructure/amqp_runner.zig`:

1. Whether to use a third-party AMQP client library or hand-roll the encoder.
2. Whether to support encrypted connections (`amqps://`).
3. Whether to pool broker connections across executions.
4. Whether to wait for publisher confirms before reporting success.
5. What to put in the AMQP message body.

Each decision is documented separately below.

## Decision 1 — Hand-rolled AMQP 0-9-1 encoder (no third-party library)

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Hand-roll encoder in stdlib** | Zero new Zig dependencies; NFR-001 compliant; AMQP 0-9-1 wire format is frozen and narrow for publish-only use | Byte-level bug risk; incremental cost for future protocol features |
| **Vendor a third-party Zig AMQP client** | Less code to write | No maintained Zig 0.15.2-compatible library exists; breaches NFR-001 and ADR-0002 |

### Decision

Encode and decode AMQP frames by hand in `src/infrastructure/amqp_runner.zig`. Encoders are byte-precise and unit-tested against pre-computed sequences derived from the AMQP 0-9-1 specification. The implemented subset covers: `Connection.Start`, `Connection.StartOk`, `Connection.Tune`, `Connection.TuneOk`, `Connection.Open`, `Connection.OpenOk`, `Channel.Open`, `Channel.OpenOk`, `Basic.Publish`, and `Connection.Close`.

### Consequences

**What becomes easier:**
- No new entries in `build.zig.zon`; NFR-001 remains unbroken.
- The implemented subset (~100 lines of wire layout) is fully covered by 8 frame-encoding tests.

**What becomes harder:**
- Byte-level bugs are possible; the test suite is the primary guard.
- Adding protocol features (publisher confirms, consumer-side, AMQP 1.0) requires incremental hand-implementation rather than a library upgrade.

---

## Decision 2 — Plaintext TCP only; `amqps://` explicitly rejected

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Plaintext TCP only; reject `amqps://`** | Minimal scope; no additional cert/CA configuration; sidecar TLS (`stunnel`) is industry-standard for this case | Production deployments with regulatory in-transit encryption requirements need an external proxy |
| **AMQPS via existing `tls_context.zig`** | Single binary handles encrypted broker connections | Requires parallel cert/CA config keys; doubles outbound TLS surface; out of scope for F019 |

### Decision

`parse_dsn` rejects `amqps://` schemes with `error.InvalidScheme`. The limitation is documented in the user guide. Production environments requiring encryption should terminate TLS via a sidecar (`stunnel`, Nginx stream proxy, or broker-side TLS offload) rather than within ztick.

### Consequences

**What becomes easier:**
- No new configuration keys for client certificates or CA bundles.
- The integration test stack runs over plaintext without extra setup.

**What becomes harder:**
- Users with in-transit encryption requirements must operate an external TLS proxy until a follow-up ADR adds AMQPS support.

---

## Decision 3 — Per-execution connect / handshake / publish / close (no connection pool)

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Per-execution connection lifecycle** | Simple state machine; no idle reaper or broker-close detection needed; AMQP handshake on localhost is ~10 ms | Opens a new TCP connection on every rule firing |
| **Per-DSN connection pool** | Amortises handshake cost across executions | Requires channel-state tracking, idle reaper, broker-side close detection, per-DSN cache; no measured contention pressure justifies the complexity |

### Decision

Open a fresh TCP connection on every execution. After `Basic.Publish`, close cleanly via `Channel.Close` then `Connection.Close`. Socket-level `SO_RCVTIMEO` and `SO_SNDTIMEO` are set to 30 seconds to cap exposure to slow or unresponsive brokers.

### Consequences

**What becomes easier:**
- Connection state is trivially correct: each execution is independent.
- The `execute()` surface does not change if pooling is added later.

**What becomes harder:**
- A slow broker can occupy a processor thread for up to 30 seconds per execution.
- At high rule-firing rates against a remote broker, handshake overhead may become measurable; pooling can be added when concrete contention evidence exists.

---

## Decision 4 — Fire-and-forget publish; no publisher confirms

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Fire-and-forget (`Basic.Publish` only)** | Lower round-trip cost; simpler channel state machine; sufficient for event fan-out use cases | `success = true` means "frame left the socket", not "message was routed and queued" |
| **Enable publisher confirms by default** | Broker acknowledgement guarantees the message was accepted | Adds `Confirm.Select` → `Basic.Ack/Nack` state machine; doubles per-publish round-trip cost; no consumer has expressed drop-detection requirements |

### Decision

Send `Basic.Publish` and treat a clean TCP write as success. `success = true` in the execution result reflects that the frame left the socket without error, not that the broker routed or queued the message. The distinction is documented in the user guide's Troubleshooting section and the Verifying-messages-arrive recipe.

### Consequences

**What becomes easier:**
- Publish latency is one round-trip (frame write + no wait).
- Channel state machine has no confirm mode; simpler to reason about and test.

**What becomes harder:**
- Misconfigured exchange or queue topology causes silent message loss.
- Users who need delivery guarantees must either inspect broker logs or implement their own confirm-mode follow-up.

---

## Decision 5 — Message body is the job identifier as a u128 hex string

### Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Job identifier (u128 hex string)** | Minimal; no format lock-in before consumers exist; consumers can look up full context via TCP `GET <job_id>` | Consumers needing richer context must make a secondary lookup |
| **JSON envelope `{job_id, execution_ts, rule_id}`** | Richer payload; no secondary lookup needed | Locks in a wire format before any consumer has expressed requirements; schema change is a breaking wire-format change |

### Decision

The message body is `request.job_identifier` serialised as a u128 hex string, matching what `encode_basic_publish` writes today. No structured envelope is included. When richer payloads are needed, they can be additive — via AMQP message properties or a versioned structured body — without breaking consumers reading today's format.

### Consequences

**What becomes easier:**
- No wire-format breakage risk: today's consumers receive the job ID and can look up context independently.
- Future payload evolution is additive; no existing consumer needs to change.

**What becomes harder:**
- Consumers needing timestamp, rule ID, or status must perform a secondary TCP `GET <job_id>` against ztick.

---

## Constitution Compliance

| Principle | Status | Justification |
|-----------|--------|---------------|
| Zero external Zig dependencies (NFR-001) | Compliant | Hand-rolled encoder; `build.zig.zon dependencies` unchanged |
| Hexagonal Architecture (ADR-0001) | Compliant | All AMQP wire logic isolated in `src/infrastructure/amqp_runner.zig`; domain and application layers untouched |
| Stdlib-only (ADR-0002) | Compliant | Only `std.net`, `std.io`, and `std.mem` used; no C interop required for plaintext AMQP |
| Minimal Abstraction | Compliant | Single `execute()` entry point; no speculative interfaces for pooling or confirms |
| TDD | Compliant | 8 frame-encoding unit tests co-located in `amqp_runner.zig` |

## References

- **Spec**: `.specify/implementation/F019/spec-content.md`
- **ADR-0001**: `docs/ADR/0001-hexagonal-architecture.md` (hexagonal architecture)
- **ADR-0002**: `docs/ADR/0002-zig-language-choice.md` (Zig stdlib-only, zero Zig package dependencies)
- **ADR-0003**: `docs/ADR/0003-openssl-tls-dependency.md` (OpenSSL TLS — outbound AMQP TLS not yet implemented)
- **AMQP 0-9-1 specification**: https://www.rabbitmq.com/resources/specs/amqp0-9-1.pdf
