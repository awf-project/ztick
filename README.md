# ztick

A time-based job scheduler written in Zig with hexagonal architecture, explicit memory management, and zero dependencies beyond the Zig standard library.

## Features

### Implemented

- **Core scheduler**: Time-based job execution with TCP control protocol
- **GET command**: Retrieve individual job state (`GET <job_id>`)
- **QUERY command**: List jobs matching a prefix pattern (`QUERY <pattern>`)
- **REMOVE / REMOVERULE commands**: Delete jobs and rules with persistent removal
- **Rules**: Match jobs by prefix and assign shell/AMQP runners
- **Persistence**: Append-only logfile with binary encoding and compression
- **Configuration**: TOML-based settings for logging, listen address, and framerate

### Roadmap

- [x] REMOVE/REMOVERULE commands for job and rule cleanup
- [ ] LISTRULES command for rule enumeration
- [ ] AMQP runner implementation (HTTP/webhook support)
- [ ] Glob pattern matching for rules (currently prefix-only)
- [ ] Result pagination for large query result sets

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

| Flag | Description |
|------|-------------|
| `-c`, `--config` | Path to TOML configuration file |

## Configuration

```toml
[log]
level = "info"              # off, error, warn, info, debug, trace

[controller]
listen = "127.0.0.1:5678"  # TCP address for protocol server

[database]
fsync_on_persist = true     # fsync after each persist write
framerate = 512             # scheduler tick rate (1-65535)
```

All values are optional and fall back to the defaults shown above.

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
