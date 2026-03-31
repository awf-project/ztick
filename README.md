# ztick

A time-based job scheduler written in Zig with hexagonal architecture, explicit memory management, and minimal dependencies.

## Features

- **Core scheduler** — Time-based job execution with TCP control protocol
- **Protocol commands** — `SET`, `GET`, `QUERY`, `REMOVE`, `REMOVERULE`, `LISTRULES`, `RULE SET`
- **Rules** — Match jobs by prefix and assign shell runners
- **Persistence** — Append-only logfile with binary encoding and automatic background compression
- **In-memory persistence** — Ephemeral mode for CI/testing without disk I/O
- **Configuration** — TOML-based settings for logging, listen address, framerate, and telemetry
- **Startup logging** — Runtime-configurable log levels with structured output
- **TLS support** — Optional TLS 1.3 encryption via system OpenSSL
- **Logfile dump** — Offline inspection with text/JSON output, compact mode, and live tail
- **OpenTelemetry** — Traces and metrics exported via OTLP/HTTP to observability collectors

## Quick Start

```bash
make build                     # build
make test                      # unit tests
make test-functional           # functional tests
make test-all                  # unit + functional tests
make test-sanitize             # tests with sanitizers (safety + thread)
make lint                      # check formatting
make fmt                       # auto-format
make clean                     # remove build artifacts
```

Run the server:

```bash
zig build run                        # run with defaults (listens on 127.0.0.1:5678)
zig build run -- -c /path/to/config  # run with config file
```

## Documentation

- **[User Guide](docs/user-guide/)** — How-to guides for common tasks
- **[Reference](docs/reference/)** — Full configuration and protocol reference
- **[ADRs](docs/ADR/)** — Architecture Decision Records

## Architecture

ztick follows **hexagonal architecture** with 4 strict layers:

1. **Domain** — Pure data types (Job, Rule, Execution) with zero dependencies
2. **Application** — Scheduler logic, storage, and query handling
3. **Infrastructure** — Adapters (TCP server, shell runner, persistence, protocol parser)
4. **Interfaces** — CLI entry point and configuration management

```
┌─────────────────────────────┐
│      Interfaces (CLI)       │
├─────────────────────────────┤
│    Infrastructure Adapters  │
│ (TCP, Shell, Persistence)   │
├─────────────────────────────┤
│   Application (Scheduler)   │
├─────────────────────────────┤
│    Domain (Data Types)      │
└─────────────────────────────┘
```

## Core Concepts

| Concept | Purpose |
|---------|---------|
| **Job** | Execution scheduled for a specific timestamp |
| **Rule** | Pattern matching rule that selects jobs and specifies a runner |
| **Runner** | Execution target (shell command) |
| **Execution** | Result of a triggered job (success/failure with metadata) |

## CLI

### Commands

| Command | Description |
|---------|-------------|
| `ztick` | Start the scheduler server (default) |
| `ztick dump <logfile>` | Inspect binary logfile contents offline |

### Server Flags

| Flag | Description |
|------|-------------|
| `-c`, `--config` | Path to TOML configuration file |

### Dump Flags

| Flag | Description |
|------|-------------|
| `--format text\|json` | Output format: human-readable text (default) or NDJSON |
| `--compact` | Show only effective state (deduplicate by ID, omit removed entries) |
| `--follow` | Live tail mode — watch for newly appended entries |

## Configuration

```toml
[log]
level = "info"              # off, error, warn, info, debug, trace

[controller]
listen = "127.0.0.1:5678"  # TCP address for protocol server

[database]
persistence = "logfile"     # persistence backend: "logfile" (default) or "memory"
logfile_path = "ztick.log"  # path to persistence logfile (logfile mode only)
fsync_on_persist = true     # fsync after each persist write (logfile mode only)
framerate = 512             # scheduler tick rate (1-65535)
compression_interval = 3600 # seconds between logfile compression (0 to disable, logfile mode only)
```

### Telemetry

```toml
[telemetry]
enabled = true                          # enable OTLP export (default: false)
endpoint = "http://localhost:4318"      # OTLP/HTTP collector endpoint
service_name = "ztick"                  # OpenTelemetry service name (default: "ztick")
flush_interval_ms = 5000                # batch flush interval in milliseconds (default: 5000)
```

All values are optional and fall back to the defaults shown above. Telemetry is disabled by default; omitting the `[telemetry]` section or setting `enabled = false` incurs zero runtime overhead.

Set `persistence = "memory"` for ephemeral operation (CI, testing, development) — no files are created or read. Data is lost on restart.

### TLS

ztick supports optional TLS encryption for the TCP protocol server. When TLS is configured, all protocol traffic (commands, job identifiers, shell commands) is encrypted in transit.

**Generate a self-signed certificate:**

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=ztick"
```

**Configure TLS in your config file:**

```toml
[controller]
listen = "127.0.0.1:5679"
tls_cert = "/path/to/cert.pem"
tls_key = "/path/to/key.pem"
```

By convention, use port `5678` for plaintext and port `5679` for TLS to avoid confusion between encrypted and unencrypted endpoints.

Both `tls_cert` and `tls_key` must be set together. If only one is provided, ztick exits with a configuration error at startup. When neither is set, ztick runs in plaintext mode (the default).

**Test the connection:**

```bash
openssl s_client -connect 127.0.0.1:5679 -quiet
```

**Requirements:** TLS support requires `libssl-dev` (Debian/Ubuntu) or `openssl-devel` (Fedora/RHEL) installed on the build machine. Plaintext-only builds have no additional dependencies. See [ADR 0003](docs/ADR/0003-openssl-tls-dependency.md) for details on the OpenSSL dependency decision.

## Threading Model

Three threads communicate via bounded channels:

- **Controller** — TCP server accepting protocol commands
- **Database** — Scheduler tick loop processing queries and triggering jobs
- **Processor** — Executes triggered jobs via shell runner

## Development

- **Zig**: 0.15.2+
- **Build dependencies**: `libssl-dev` (Debian/Ubuntu) or `openssl-devel` (Fedora/RHEL) for TLS support
- **Testing**: Co-located unit tests + functional tests in `src/functional_tests.zig`
- **Sanitizers**: `make test-sanitize` runs with safety checks and thread sanitizer
- **Formatting**: Enforced with `zig fmt` (`make lint`)

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## License

Licensed under the [European Union Public Licence v1.2](LICENSE) (EUPL-1.2).
