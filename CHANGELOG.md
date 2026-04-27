# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **AMQP runner (F019)** — Hand-rolled, stdlib-only AMQP 0-9-1 publisher in `src/infrastructure/amqp_runner.zig`. Rules with runner type `amqp` now actually publish to a broker on match (previously returned `error.UnsupportedRunner`). Each execution opens a fresh TCP connection, runs the full handshake (Start/StartOk → Tune/TuneOk → Open/OpenOk → Channel.Open → Basic.Publish → Channel.Close → Connection.Close), then closes — fire-and-forget, no publisher confirms. The message body is the job identifier as a u128 hex string. DSN credentials are redacted at every log site (NFR-002). Plaintext only — `amqps://` is rejected at parse time and TLS deferred (see ADR-0005). Connection refused, authentication rejection (server-initiated `Connection.Close` with reply-code 403), malformed DSNs, and slow brokers all return `success = false` without crashing the processor; 30 s `SO_RCVTIMEO`/`SO_SNDTIMEO` caps slow-broker exposure. Bundled `compose.yaml` boots a RabbitMQ 4.3 dev stack with the management UI on `:15672`. Optional broker-dependent integration tests are gated by a new `-Damqp-integration` build flag. ADR-0005 documents the design decisions.
- **STAT command with authentication wiring (F018)** — Server health metrics query with 15 key-value metrics (uptime, connection count, job/rule counts, execution pipeline state, persistence backend, compression status, auth/TLS configuration). STAT reports `auth_enabled` based on server configuration and requires authentication when `auth_file` is configured. STAT is namespace-independent — any authenticated client can call it regardless of token scope.
- EUPL v1.2 license file
- `.editorconfig` for consistent code formatting

## [0.1.0] - 2026-03-31

Initial release of ztick, a time-based job scheduler written in Zig with
hexagonal architecture.

### Added

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
