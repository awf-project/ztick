# Configuration

This guide covers setting up and customizing ztick through TOML configuration files.

## Configuration File Location

Specify the config file when starting ztick:

```bash
zig build run -- -c /path/to/config.toml
```

If no `-c` is provided, ztick uses built-in defaults.

## Configuration Sections

### `[log]` — Logging

Controls what and how much is logged.

```toml
[log]
level = "info"
```

**Options:**

| Option | Values | Default | Notes |
|--------|--------|---------|-------|
| `level` | `off`, `error`, `warn`, `info`, `debug`, `trace` | `info` | Minimum log level to output |

**Examples:**

```toml
# Production (errors only)
[log]
level = "error"

# Development (all messages)
[log]
level = "debug"
```

### `[controller]` — TCP Server

Configuration for the TCP protocol server.

```toml
[controller]
listen = "127.0.0.1:5678"
```

**Options:**

| Option | Type | Default | Notes |
|--------|------|---------|-------|
| `listen` | string | `127.0.0.1:5678` | TCP address and port to listen on |
| `tls_cert` | string (path) | (optional) | Path to PEM-encoded TLS certificate |
| `tls_key` | string (path) | (optional) | Path to PEM-encoded TLS private key |

**Examples:**

```toml
# Listen on all interfaces
[controller]
listen = "0.0.0.0:5678"

# Listen on IPv6
[controller]
listen = "[::1]:5678"

# Non-standard port
[controller]
listen = "127.0.0.1:9999"

# Enable TLS encryption (use port 5679 by convention)
[controller]
listen = "127.0.0.1:5679"
tls_cert = "/etc/ztick/cert.pem"
tls_key = "/etc/ztick/key.pem"
```

### Setting Up TLS

ztick supports optional TLS encryption for secure communication. When configured, all protocol traffic is encrypted in transit.

**Requirements:**
- `libssl-dev` (Debian/Ubuntu) or `openssl-devel` (Fedora/RHEL) on build machine
- PEM-format certificate and private key files

**Generate a self-signed certificate:**

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=ztick"
```

This creates:
- `cert.pem` — Public certificate (valid for 365 days)
- `key.pem` — Private key (unencrypted with `-nodes`)

**Enable in config:**

```toml
[controller]
listen = "127.0.0.1:5679"
tls_cert = "/path/to/cert.pem"
tls_key = "/path/to/key.pem"
```

By convention, use port `5678` for plaintext and port `5679` for TLS to avoid confusion between encrypted and unencrypted endpoints.

**Test the connection:**

```bash
openssl s_client -connect 127.0.0.1:5679 -quiet
```

**Important notes:**
- Both `tls_cert` and `tls_key` **must be set together**
- If only one is provided, ztick exits with a configuration error
- Omit both to run in plaintext mode (default)
- When TLS is disabled, the server functions identically to earlier versions — plaintext mode is fully backward compatible

### `[database]` — Persistence and Timing

Controls how jobs and rules are stored and when they are evaluated.

```toml
[database]
persistence = "logfile"
fsync_on_persist = true
framerate = 512
logfile_path = "logfile"
```

**Options:**

| Option | Type | Default | Notes |
|--------|------|---------|-------|
| `persistence` | string | `"logfile"` | Persistence backend: `"logfile"` or `"memory"` |
| `fsync_on_persist` | boolean | `true` | Flush writes to disk immediately (safer, slower; ignored for `persistence = "memory"`) |
| `framerate` | integer | `512` | Evaluation frequency in Hz (valid range: 1-65535) |
| `logfile_path` | string | `"logfile"` | Path to the binary logfile (ignored for `persistence = "memory"`) |
| `compression_interval` | integer | `3600` | Background compression interval in seconds; `0` disables compression (logfile backend only) |

#### Persistence Modes

**Logfile persistence (default):** `persistence = "logfile"`

```toml
[database]
persistence = "logfile"
logfile_path = "data/ztick.log"
fsync_on_persist = true
framerate = 512
```

Use logfile persistence for any deployment requiring **durability**. Jobs and rules are written to disk and survive restarts. Recommended for production systems.

**In-memory persistence:** `persistence = "memory"`

```toml
[database]
persistence = "memory"
framerate = 512
```

Use in-memory persistence for **ephemeral deployments** where data does not need to survive restarts:
- CI/testing environments where a fresh scheduler instance is preferred for each run
- Temporary job scheduling without long-term history
- Development and debugging with reduced I/O overhead

When `persistence = "memory"` is set, `logfile_path` and `fsync_on_persist` are ignored and no files are created on disk. All jobs and rules are lost when ztick stops.

#### Compression Scheduling

When using logfile persistence, ztick automatically compresses the logfile on a periodic interval to reduce disk usage. The `compression_interval` setting controls how often compression runs:

- `compression_interval = 3600` (default) — Compress once per hour
- `compression_interval = 1800` — Compress every 30 minutes (for high-mutation workloads)
- `compression_interval = 0` — Disable compression entirely

Compression runs in the background without blocking job processing. Memory backend deployments ignore this setting and never compress.

**Examples:**

```toml
# High reliability
[database]
fsync_on_persist = true
framerate = 512

# High throughput (accept some data loss risk)
[database]
fsync_on_persist = false
framerate = 1000

# Low resource usage
[database]
fsync_on_persist = true
framerate = 1
```

### `[telemetry]` — Observability

Export metrics, traces, and logs to an OpenTelemetry collector for monitoring and debugging.

```toml
[telemetry]
enabled = true
endpoint = "http://localhost:4318"
service_name = "ztick"
flush_interval_ms = 5000
```

**Options:**

| Option | Type | Default | Notes |
|--------|------|---------|-------|
| `enabled` | boolean | `false` | Enable telemetry export (zero overhead when disabled) |
| `endpoint` | string | (required if enabled) | OTLP/HTTP collector URL (e.g., `http://localhost:4318`) |
| `service_name` | string | `"ztick"` | Service name in observability backend |
| `flush_interval_ms` | integer | `5000` | Batch export interval in milliseconds |

**Telemetry is exported to:**
- **Metrics** → `POST /v1/metrics` (job counts, execution latency, connection gauges)
- **Traces** → `POST /v1/traces` (request spans with command, request ID, and success attributes)
- **Logs** → `POST /v1/logs` (warn-level and above, with trace correlation)

**Examples:**

```toml
# No monitoring (default)
[telemetry]
enabled = false

# Local development with Jaeger/OpenTelemetry Collector
[telemetry]
enabled = true
endpoint = "http://localhost:4318"
service_name = "ztick-dev"
flush_interval_ms = 5000

# Production with Grafana Agent (remote backend)
[telemetry]
enabled = true
endpoint = "http://grafana-agent.infra.svc.cluster.local:4318"
service_name = "ztick-prod"
flush_interval_ms = 10000

# High-volume deployment (more frequent flushes)
[telemetry]
enabled = true
endpoint = "http://otel-collector:4318"
service_name = "ztick-high-volume"
flush_interval_ms = 1000
```

## Full Configuration Example

**Persistent deployment with telemetry:**

```toml
[log]
level = "info"

[controller]
listen = "127.0.0.1:5678"

[database]
persistence = "logfile"
fsync_on_persist = true
framerate = 512
logfile_path = "logfile"
compression_interval = 3600

[telemetry]
enabled = true
endpoint = "http://localhost:4318"
service_name = "ztick"
flush_interval_ms = 5000
```

**Ephemeral deployment (CI/testing):**

```toml
[log]
level = "info"

[controller]
listen = "127.0.0.1:5678"

[database]
persistence = "memory"
framerate = 512

[telemetry]
enabled = false
```

## Default Configuration

If no configuration file is provided, ztick uses these defaults:

```toml
[log]
level = "info"

[controller]
listen = "127.0.0.1:5678"

[database]
persistence = "logfile"
fsync_on_persist = true
framerate = 512
logfile_path = "logfile"
compression_interval = 3600

[telemetry]
enabled = false
service_name = "ztick"
flush_interval_ms = 5000
```

When telemetry is disabled (the default), all instrumentation and observability exports are disabled and have zero overhead.

## Configuration Best Practices

### Development

```toml
[log]
level = "debug"

[controller]
listen = "127.0.0.1:5678"

[database]
persistence = "memory"
framerate = 512

[telemetry]
enabled = false
```

- Higher verbosity for debugging
- Default evaluation rate
- In-memory persistence for quick iteration (no disk clutter)
- Telemetry disabled by default (zero overhead in development)

**Optional:** Enable telemetry to test with a local OpenTelemetry Collector:

```toml
[telemetry]
enabled = true
endpoint = "http://localhost:4318"
service_name = "ztick-dev"
flush_interval_ms = 5000
```

### Production

```toml
[log]
level = "warn"

[controller]
listen = "0.0.0.0:5679"
tls_cert = "/etc/ztick/cert.pem"
tls_key = "/etc/ztick/key.pem"

[database]
persistence = "logfile"
fsync_on_persist = true
framerate = 512
logfile_path = "/var/lib/ztick/logfile"

[telemetry]
enabled = true
endpoint = "http://otel-collector.infra.svc.cluster.local:4318"
service_name = "ztick-prod"
flush_interval_ms = 10000
```

- Minimal logging (errors and warnings only)
- Listen on all interfaces with TLS encryption (port 5679)
- Durable logfile persistence
- Telemetry enabled for observability and alerting

### High-Volume

```toml
[log]
level = "error"

[controller]
listen = "0.0.0.0:5678"

[database]
persistence = "logfile"
fsync_on_persist = false
framerate = 1000
compression_interval = 300

[telemetry]
enabled = true
endpoint = "http://otel-collector:4318"
service_name = "ztick-high-volume"
flush_interval_ms = 1000
```

- Errors only
- Higher evaluation frequency
- Relaxed persistence (batch writes for throughput)
- Aggressive compression (every 5 minutes) for rapid logfile growth
- Telemetry enabled with frequent flushes (1s) to capture high-frequency events

## Troubleshooting

### "Address already in use"

Another process is using the configured port. Either:
1. Stop the other process: `lsof -i :5678`
2. Change the port in config.toml: `listen = "127.0.0.1:9999"`

### "Permission denied" on listen

Non-root users cannot listen on ports below 1024. Use:

```toml
[controller]
listen = "127.0.0.1:5678"  # 1024 or above
```

### Very slow evaluation

If jobs aren't triggering on time, check the `framerate` setting:

```toml
[database]
framerate = 512  # default: evaluate 512 times per second (~2ms latency)
```

### Data loss after crash

Enable safe persistence:

```toml
[database]
fsync_on_persist = true
```

This ensures every job/rule write is flushed to disk immediately.
