# ztick

A push-driven, time-based job scheduler written in Zig with hexagonal architecture, explicit memory management, and minimal dependencies.

Periodic schedulers (cron, systemd timers) trigger work at fixed intervals regardless of system state. ztick inverts this logic: the application sends a `SET` command over TCP at the moment it sees fit, and ztick faithfully executes it at the requested time.

## Features

- TCP control protocol (`AUTH`, `SET`, `GET`, `QUERY`, `REMOVE`, `RULE SET`, `LISTRULES`, `STAT`) with optional TLS 1.3
- Optional REST/JSON HTTP API with embedded OpenAPI 3.1.1 spec
- Rule-based dispatch: shell, direct execve, HTTP webhook, AWF workflow, AMQP publisher, Redis command
- Token-based AUTH with namespace-scoped authorization
- Append-only logfile persistence with binary framing and background compression; in-memory mode for ephemeral runs
- TOML configuration; OpenTelemetry traces and metrics over OTLP/HTTP
- Offline `dump` subcommand to inspect logfiles (text/JSON, compact, follow)
- Documentation site with Hugo/Thulite (Doks) and GitHub Pages auto-deployment

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/download/) >= 0.15.2
- `libssl-dev` (Debian/Ubuntu) or `openssl-devel` (Fedora/RHEL) for TLS support

### Install

Install the latest pre-built binary with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/awf-project/ztick/main/scripts/install.sh | sh
```

Supported platforms: Linux (x86_64, arm64), macOS (universal).

### Build from Source

```bash
make build         # build the server binary (Debug)
make release       # ReleaseSafe optimized build
make install       # install ReleaseSafe binary to $INSTALL_DIR (default ~/.local/bin)
make test          # unit tests with integration brokers
make test-all      # unit + functional tests
make lint          # check formatting
```

The built binary is located at `zig-out/bin/ztick`. Run `make help` to list every target.

### Run

```bash
zig build run                         # listens on 127.0.0.1:5678 with defaults
zig build run -- -c /path/to/config   # run with a TOML config file
ztick dump ztick.log --follow         # tail a persistence logfile
```

Schedule a job:

```bash
echo "SET deploy.daily $(date +%s%N -d 'tomorrow 03:00')" | nc 127.0.0.1 5678
```

### Local Development Stack

A `compose.yaml` at the repository root provides RabbitMQ 4.3 and Redis 7 for runner integration tests:

```bash
docker compose up -d
docker compose down
```

## Documentation

Browse the documentation online at **https://awf-project.github.io/ztick/** or in the [`docs/`](docs/) directory:

- [Tutorials](docs/tutorials/) — Build, run, and verify your first instance
- [User Guide](docs/user-guide/) — Jobs, rules, authentication, configuration, monitoring
- [Reference](docs/reference/) — Configuration schema, HTTP API, native protocol, persistence format
- [Development](docs/development/) — Architecture, build, contributing
- [ADR](docs/ADR/) — Architecture Decision Records

To preview the documentation site locally:

```bash
cd site && npm ci && npm run dev
```

## License

Licensed under the [European Union Public Licence v1.2](LICENSE) (EUPL-1.2).
