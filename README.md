# ztick

A time-based job scheduler written in Zig with hexagonal architecture, explicit memory management, and zero dependencies beyond the Zig standard library.

## Features

### Implemented

- **Core scheduler**: Time-based job execution with TCP control protocol
- **GET command**: Retrieve individual job state (`GET <job_id>`)
- **QUERY command**: List jobs matching a prefix pattern, or all jobs (`QUERY [<pattern>]`)
- **REMOVE / REMOVERULE commands**: Delete jobs and rules with persistent removal
- **LISTRULES command**: Enumerate all configured rules (`LISTRULES`)
- **Rules**: Match jobs by prefix and assign shell/AMQP runners
- **Persistence**: Append-only logfile with binary encoding and automatic background compression
- **Compression scheduling**: Time-based background compression to reduce disk usage on long-lived deployments
- **Configuration**: TOML-based settings for logging, listen address, and framerate
- **Startup logging**: Runtime-configurable log levels with structured output for startup, connections, and execution lifecycle
- **TLS support**: Optional TLS encryption for TCP protocol traffic using system OpenSSL
- **Logfile dump**: Offline inspection of binary logfiles with text/JSON output, compact mode, and live tail
- **In-memory persistence**: Optional ephemeral operation mode for CI/testing without disk I/O

## Quick Start

### Build

```bash
zig build
zig build -Doptimize=ReleaseSafe  # optimized build
```

### Run

```bash
zig build run                        # run with defaults (listens on 127.0.0.1:5678)
zig build run -- -c /path/to/config  # run with config file
```

### Test

```bash
zig build test                 # all unit tests
zig build test-all             # unit + functional tests
zig build test-domain          # domain layer only
zig build test-application     # application layer only
zig build test-infrastructure  # infrastructure layer only
zig build test-interfaces      # interfaces layer only
zig build test-functional      # functional tests only
zig build fmt-check            # check formatting
```

## Documentation

- **[ADRs](docs/ADR/)** — Architecture Decision Records
- **[Configuration](docs/reference/configuration.md)** — Full configuration reference

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
| **Runner** | Execution target (shell command, AMQP, HTTP) |
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
logfile_path = "logfile"    # path to persistence logfile (logfile mode only)
fsync_on_persist = true     # fsync after each persist write (logfile mode only)
framerate = 512             # scheduler tick rate (1-65535)
compression_interval = 3600 # seconds between logfile compression (0 to disable, logfile mode only)
```

All values are optional and fall back to the defaults shown above.

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

- **Zig**: 0.14.1+
- **Testing**: Co-located unit tests + functional tests in `src/functional_tests.zig`
- **Formatting**: Enforced with `zig fmt` (`zig build fmt-check`)

## License

See [LICENSE](LICENSE) file.
