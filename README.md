# ztick

A time-based job scheduler written in Zig with hexagonal architecture, explicit memory management, and minimal dependencies.

## Why ztick?

Periodic schedulers (cron, systemd timers) trigger work at fixed intervals regardless of the target system's state. When load is already high, they make it worse.

ztick inverts this logic: the application decides when to schedule a job based on its own state. It sends a `SET` command over TCP at the moment it sees fit, and ztick faithfully executes it at the requested time.

This is an **explicit push model** — the application drives, ztick executes. There is intentionally no built-in periodic trigger mechanism.

## Features

- **Core scheduler** — Time-based job execution with TCP control protocol
- **Protocol commands** — `AUTH`, `SET`, `GET`, `QUERY`, `REMOVE`, `REMOVERULE`, `LISTRULES`, `RULE SET`, `STAT`
- **Rules** — Match jobs by prefix and assign shell, direct, HTTP webhook, or AWF workflow runners
- **HTTP webhooks** — Trigger external services via GET/POST/PUT/DELETE requests with JSON payloads
- **Client authentication** — Token-based AUTH handshake with namespace-scoped authorization
- **Persistence** — Append-only logfile with binary encoding and automatic background compression
- **In-memory persistence** — Ephemeral mode for CI/testing without disk I/O
- **Configuration** — TOML-based settings for logging, listen address, framerate, and telemetry
- **Startup logging** — Runtime-configurable log levels with structured output
- **TLS support** — Optional TLS 1.3 encryption via system OpenSSL
- **Logfile dump** — Offline inspection with text/JSON output, compact mode, and live tail
- **OpenTelemetry** — Traces and metrics exported via OTLP/HTTP to observability collectors
- **OpenAPI contract** — Machine-readable API specification (`openapi.yaml`) for the HTTP controller

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
- **[Reference](docs/reference/)** — Configuration, HTTP API, protocol, and data types
  - **[HTTP API](docs/reference/http-api.md)** — REST endpoints and authentication
  - **[OpenAPI Specification](openapi.yaml)** — Machine-readable v3.1.1 contract
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
| **Runner** | Execution target (shell command, direct execve, HTTP webhook, or AWF workflow) |
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
auth_file = "auth.toml"     # optional: path to auth token file (disabled if unset)

[shell]
path = "/bin/bash"          # shell binary for shell runners (default: /bin/sh)
args = ["-c"]               # arguments passed before the command string

[database]
persistence = "logfile"     # persistence backend: "logfile" (default) or "memory"
logfile_path = "ztick.log"  # path to persistence logfile (logfile mode only)
fsync_on_persist = true     # fsync after each persist write (logfile mode only)
framerate = 512             # scheduler tick rate (1-65535)
compression_interval = 3600 # seconds between logfile compression (0 to disable, logfile mode only)
```

### Authentication

ztick supports optional token-based client authentication. When `auth_file` is configured in the `[controller]` section, all TCP connections must authenticate with the `AUTH` command before issuing other commands.

**Auth File Format (TOML):**

```toml
[token.deploy]
secret = "sk_deploy_a1b2c3d4e5f6"
namespace = "deploy."

[token.backup]
secret = "sk_backup_x9y8z7w6v5u4"
namespace = "*"
```

- Each `[token.<name>]` section defines a token with a `secret` and `namespace`
- `secret` — Any string value (treated as plaintext)
- `namespace` — Prefix that restricts which jobs/rules the token can access, or `"*"` for unrestricted access

When authentication is disabled (no `auth_file` configured), all connections are accepted without the AUTH step — this is the default and maintains backward compatibility.

**Token Namespaces:**
- A token with namespace `deploy.` can only access jobs/rules matching the prefix (e.g., `deploy.daily`, `deploy.release.1`)
- A token with namespace `*` can access all jobs/rules
- Commands targeting identifiers outside the token's namespace are rejected with `ERROR`

See [Configuring Authentication](docs/user-guide/authentication.md) for setup and examples.

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

Four threads communicate via bounded channels:

- **Controller** — TCP server accepting protocol commands
- **Database** — Scheduler tick loop processing queries and triggering jobs
- **Processor** — Executes triggered jobs via shell, direct, AWF, or HTTP runners
- **HTTP** — Optional REST API server (enabled via `[http]` config section)

## Development

- **Zig**: 0.15.2+
- **Build dependencies**: `libssl-dev` (Debian/Ubuntu) or `openssl-devel` (Fedora/RHEL) for TLS support
- **Testing**: Co-located unit tests + functional tests in `src/functional_tests.zig`
- **Sanitizers**: `make test-sanitize` runs with safety checks and thread sanitizer
- **Formatting**: Enforced with `zig fmt` (`make lint`)

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## License

Licensed under the [European Union Public Licence v1.2](LICENSE) (EUPL-1.2).
