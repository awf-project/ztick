# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.0] - 2026-05-13

### Changed

- **Hexagonal architecture refactoring** — Extracted persistence codec from infrastructure to application layer (`persistence_codec.zig`), introduced vtable-based `PersistencePort` interface to decouple the scheduler from concrete backends, and made `Scheduler` generic via `SchedulerWith(comptime Backend: type)`. Promoted domain types (`timestamp.zig`, `shell_config.zig`, `telemetry_config.zig`) and OTel instruments (`instruments.zig`) out of infrastructure into their proper layers. Extracted shared subprocess logic into `runner/subprocess.zig`.

## [0.2.0] - 2026-05-11

### Added

- **Thread-per-connection HTTP concurrency (F022)** — HTTP server now spawns a detached thread per accepted connection so multiple clients can issue requests simultaneously without blocking the accept loop. An `active_connections` atomic counter and `join_all()` with 5-second polling timeout enable graceful shutdown that drains in-flight requests before process exit.
- **Channel batch drain** — `Channel.drain()` batch-consumes all pending requests in a single lock/unlock cycle, reducing lock contention from per-message to per-tick under concurrent TCP workers.
- **Event-driven database tick** — `Clock` now uses condition-variable `timedWait()` instead of unconditional `Thread.sleep()`, waking the database thread immediately when a request arrives. Cuts single-worker p50 latency from ~2 ms to sub-millisecond.

### Changed

- **Priority queue for job storage (F021)** — `JobStorage` replaced sorted `ArrayList` with `std.PriorityQueue` for O(log n) job insertion, eliminating linear scan overhead as the scheduled job count grows.
- Normalized public API naming to `snake_case` (`setInstruments` → `set_instruments`, `setStatContext` → `set_stat_context`) and private HTTP helpers (`toEpochSeconds` → `to_epoch_seconds`, `isLeapYear` → `is_leap_year`).
- Query channel capacity expanded from 64 to 1024.
- Forced LLVM backend for all build targets to work around a glibc 2.43+ `.sframe` relocation incompatibility with Zig's self-hosted linker (ziglang/zig#31272).

### Fixed

- HTTP server returned `405 Method Not Allowed` instead of `404 Not Found` for unmatched rule routes.
- AWF runner arg-freeing logic now uses index-based iteration to avoid use-after-free.

## [0.1.0] - 2026-04-27

Initial release of ztick, a time-based job scheduler written in Zig with
hexagonal architecture.

### Added
- **Redis runner (F020)** — Hand-rolled, stdlib-only RESP2 codec (`src/infrastructure/redis/resp.zig`) and Redis adapter (`src/infrastructure/runner/redis.zig`) issuing `PUBLISH`, `RPUSH`, `LPUSH`, or `SET` commands per matching job. Rules with runner type `redis` now dispatch to a Redis server; allowed commands are validated case-sensitively at `RULE SET` parse time so unsupported commands (e.g. `FLUSHALL`) are rejected before persistence. URL format `redis://[user[:password]@]host[:port][/db]`; `rediss://` is rejected at parse time and TLS deferred (see ADR-0006). Each execution opens a fresh TCP connection, optionally sends `AUTH` (single-arg or ACL two-arg form) then `SELECT <db>` when `db != 0`, sends the configured command with the job identifier as the value/payload, then closes — fire-and-forget, no pooling. URL credentials are redacted at every log site (NFR-002). `PUBLISH` with zero subscribers is treated as success (matches `redis-cli` defaults); RESP error replies, connection refused, malformed URLs, and slow brokers all return `success = false` without crashing the processor; 30 s `SO_RCVTIMEO`/`SO_SNDTIMEO` caps slow-broker exposure. Persistence uses discriminant byte `5` (the next available value after `0=shell`, `1=amqp`, `2=direct`, `3=awf`, `4=http`); existing logfiles are unaffected. Bundled `compose.yaml` boots a `redis:7-alpine` service bound to `127.0.0.1:6379`. Optional broker-dependent integration tests are gated by a new `-Dredis-integration` build flag. ADR-0006 documents the design decisions.
- **AMQP runner (F019)** — Hand-rolled, stdlib-only AMQP 0-9-1 publisher in `src/infrastructure/amqp_runner.zig`. Rules with runner type `amqp` now actually publish to a broker on match (previously returned `error.UnsupportedRunner`). Each execution opens a fresh TCP connection, runs the full handshake (Start/StartOk → Tune/TuneOk → Open/OpenOk → Channel.Open → Basic.Publish → Channel.Close → Connection.Close), then closes — fire-and-forget, no publisher confirms. The message body is the job identifier as a u128 hex string. DSN credentials are redacted at every log site (NFR-002). Plaintext only — `amqps://` is rejected at parse time and TLS deferred (see ADR-0005). Connection refused, authentication rejection (server-initiated `Connection.Close` with reply-code 403), malformed DSNs, and slow brokers all return `success = false` without crashing the processor; 30 s `SO_RCVTIMEO`/`SO_SNDTIMEO` caps slow-broker exposure. Bundled `compose.yaml` boots a RabbitMQ 4.3 dev stack with the management UI on `:15672`. Optional broker-dependent integration tests are gated by a new `-Damqp-integration` build flag. ADR-0005 documents the design decisions.
- **STAT command with authentication wiring (F018)** — Server health metrics query with 15 key-value metrics (uptime, connection count, job/rule counts, execution pipeline state, persistence backend, compression status, auth/TLS configuration). STAT reports `auth_enabled` based on server configuration and requires authentication when `auth_file` is configured. STAT is namespace-independent — any authenticated client can call it regardless of token scope.
- **Core scheduler** with three-thread architecture (controller, database,
  processor) and bounded FIFO channels for inter-thread communication
- **TCP protocol** — line-based text protocol on `127.0.0.1:5678` with
  request/response routing and quoted string support
  - `SET` — schedule a job at a given timestamp
  - `GET` — retrieve a single job by ID
  - `QUERY` — prefix-based job lookup with multi-line response
  - `REMOVE` — delete a job by ID
  - `RULE SET` — create a recurring rule with runner type
  - `REMOVERULE` — delete a rule by ID
  - `LISTRULES` — list all configured rules
- **Persistence** — append-only logfile with 4-byte length-prefixed binary
  framing, supporting jobs, rules, and removal entries
- **In-memory persistence backend** — alternative to logfile for ephemeral
  workloads, selectable via `persistence = "memory"` in config
- **Background compression** — scheduled deduplication of logfile entries with
  atomic rename, clock regression guard, and configurable interval
- **Shell runner** — execute shell commands on job trigger
- **TLS encryption** — optional TLS 1.3 via system OpenSSL with `tls_cert` and
  `tls_key` configuration (ADR-0003)
- **Logfile dump command** — offline inspection with text, JSON, and compact
  output modes, plus follow (tail) mode with signal handling
- **Startup logging** — configurable log levels (off, error, warn, info, debug,
  trace) with data restoration and connection lifecycle logging
- **OpenTelemetry instrumentation** — distributed tracing and metrics via
  OTLP/HTTP using zig-o11y/opentelemetry-sdk (ADR-0004)
  - `ztick.request` spans with server span kind, command type, request ID, and
    success attributes
  - `service.name` and `service.version` resource attributes via custom
    `ResourceAwareOTLPExporter`
- **Configuration** — custom TOML parser with sections for `[log]`,
  `[controller]`, `[database]`, and `[telemetry]`
- **Hexagonal architecture** — four strict layers (domain, application,
  infrastructure, interfaces) with barrel exports
- **Comprehensive documentation** — ADRs, user guides, reference docs, tutorials,
  and example configurations
- **Functional test suite** — integration tests covering all protocol commands,
  persistence backends, TLS, dump modes, compression, and telemetry
