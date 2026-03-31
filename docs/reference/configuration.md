# Configuration Reference

Complete specification of all TOML configuration options.

ztick is configured via a TOML file passed with the `-c` / `--config` flag. All sections and keys are optional; omitted values use the defaults below.

```bash
zig build run -- -c /path/to/config.toml
```

## Sections

### `[log]`

Logging configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `level` | string | `"info"` | Log verbosity threshold: `off`, `error`, `warn`, `info`, `debug`, `trace`. Messages at or above this level are written to stderr; messages below are suppressed. |

**Levels** (ordered from least to most verbose):
- `off` — All log output suppressed, including startup messages
- `error` — Errors only (e.g. controller start failures)
- `warn` — Warnings and above (e.g. database load failures)
- `info` — Startup info (config path, log level, listen address, loaded job/rule counts), client connect/disconnect, and above (recommended for production)
- `debug` — Instruction receipt, execution outcomes, and above
- `trace` — Maximum verbosity (maps to debug internally)

### `[controller]`

TCP server configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `listen` | string | `"127.0.0.1:5678"` | TCP address and port for the protocol server |
| `tls_cert` | string (path) | `null` | Path to PEM-encoded TLS certificate file (requires `tls_key` to be set) |
| `tls_key` | string (path) | `null` | Path to PEM-encoded TLS private key file (requires `tls_cert` to be set) |

**Address Format**: `<host>:<port>` where host is IPv4 or IPv6
- `127.0.0.1:5678` — Localhost only
- `0.0.0.0:5678` — All interfaces (IPv4)
- `[::1]:5678` — Localhost only (IPv6)

**TLS Configuration Notes:**
- Both `tls_cert` and `tls_key` must be set together to enable TLS
- If only one is set, ztick exits with `ConfigError.InvalidValue` at startup
- Omit both to run in plaintext mode (default)
- By convention, use port `5678` for plaintext and port `5679` for TLS to avoid confusion between encrypted and unencrypted endpoints
- Requires `libssl-dev` (Debian/Ubuntu) or equivalent on the build machine
- See [README TLS section](../../README.md#tls) for certificate generation instructions

### `[database]`

Persistence and scheduling configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `persistence` | string | `"logfile"` | Persistence backend: `"logfile"` (disk-backed, persistent) or `"memory"` (ephemeral, no disk I/O) |
| `logfile_path` | string | `"logfile"` | Path to the append-only persistence logfile (ignored when `persistence = "memory"`) |
| `fsync_on_persist` | bool | `true` | Call fsync after each persistence write (safer, slower; ignored when `persistence = "memory"`) |
| `framerate` | integer | `512` | Scheduler tick rate in Hz (valid range: 1-65535) |
| `compression_interval` | integer (seconds) | `3600` | Interval between background compression cycles in seconds; set to `0` to disable compression (logfile backend only; ignored for memory backend) |

### `[telemetry]`

Observability and monitoring configuration via OpenTelemetry.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Enable telemetry export to an OTLP collector. When disabled (default), no observability data is exported and telemetry instrumentation has zero overhead. |
| `endpoint` | string | (required if enabled) | HTTP endpoint of the OpenTelemetry collector (e.g., `"http://localhost:4318"`). The collector must accept OTLP/HTTP JSON at `/v1/metrics`, `/v1/traces`, and `/v1/logs` paths. |
| `service_name` | string | `"ztick"` | Logical name for this service in observability backends (appears as `service.name` resource attribute). |
| `flush_interval_ms` | integer (milliseconds) | `5000` | Batch export interval in milliseconds. Accumulated metrics, traces, and logs are sent to the collector at this interval. |

**Telemetry Features:**
- **Metrics**: Job throughput (`ztick.jobs.scheduled`, `ztick.jobs.executed`, `ztick.jobs.removed`), execution latency (`ztick.execution.duration_ms`), connection counts (`ztick.connections.active`), rule counts (`ztick.rules.active`), and compression events (`ztick.persistence.compactions`).
- **Traces**: `ztick.request` span (kind: server) covering TCP request lifecycle (receive → parse → dispatch → response), with attributes `ztick.command`, `ztick.request.id`, and `ztick.success`.
- **Structured Logs**: Log records at warn level and above, correlated with traces via shared trace IDs.
- **Resource Attributes**: All signals include `service.name` and `service.version` resource attributes.
- **Resilience**: Export failures do not impact scheduler operation; ztick continues processing jobs normally when the collector is unreachable.

**Configuration Examples:**

```toml
# Telemetry disabled (default — zero overhead)
[telemetry]
enabled = false

# Telemetry enabled with local collector
[telemetry]
enabled = true
endpoint = "http://localhost:4318"
service_name = "my-ztick-instance"
flush_interval_ms = 5000

# Telemetry enabled with remote collector (Datadog, Grafana Agent, etc.)
[telemetry]
enabled = true
endpoint = "http://otel-collector.observability.svc.cluster.local:4318"
service_name = "ztick-prod"
flush_interval_ms = 10000
```

**Collector Compatibility:**
- Tested with OpenTelemetry Collector (`otelcontribcol`)
- Compatible with any OTLP/HTTP JSON receiver (Datadog Agent, Grafana Agent, New Relic, etc.)
- Metrics and traces are exported via OTLP/HTTP protobuf to `POST /v1/metrics` and `POST /v1/traces` respectively
- Requires the collector to be reachable and healthy for export; unavailable collectors do not cause scheduler failures

**Persistence Modes:**
- `"logfile"` — (default) Store jobs and rules in an append-only binary logfile. Data persists across restarts. Use for production deployments where durability is critical.
- `"memory"` — Store jobs and rules only in memory. No disk I/O occurs. Data is lost on shutdown. Useful for ephemeral deployments, CI environments, and testing where durability is not required.

**Compression Interval**:
- `0` — Disable automatic compression entirely
- `3600` — Default, compress once per hour
- `60` — Compress every minute (high-mutation workloads)

Compression runs in a background thread and does not block the scheduler tick loop. When the persistence backend is `"memory"`, compression is completely inactive regardless of this setting. If a leftover `.to_compress` file exists at startup (from a previously interrupted compression), it is compressed before the periodic timer begins. If a compression cycle is still running when the next interval triggers, the cycle is skipped.

**Framerate**:
- `1` — Evaluate once per second (low CPU, long latency)
- `512` — Default, evaluate 512 times per second (~2ms latency)
- `1000` — Evaluate 1000 times per second (~1ms latency)

## Full Example

```toml
[log]
level = "debug"

[controller]
listen = "0.0.0.0:5679"
tls_cert = "/etc/ztick/cert.pem"
tls_key = "/etc/ztick/key.pem"

[database]
persistence = "logfile"
logfile_path = "data/ztick.log"
fsync_on_persist = false
framerate = 100
compression_interval = 1800

[telemetry]
enabled = true
endpoint = "http://otel-collector:4318"
service_name = "ztick-prod"
flush_interval_ms = 10000
```

## Errors

| Error | Cause |
|-------|-------|
| `InvalidLogLevel` | `level` is not one of the valid values |
| `FramerateOutOfRange` | `framerate` is 0 or exceeds 65535 |
| `UnknownSection` | Section name is not `log`, `controller`, `database`, or `telemetry` |
| `UnknownKey` | Key is not recognized within its section |
| `InvalidValue` | Value cannot be parsed (e.g. non-boolean for `fsync_on_persist`), or only one of `tls_cert`/`tls_key` is set, or `persistence` is not `"logfile"` or `"memory"`, or `telemetry.enabled = true` but `endpoint` is missing/malformed, or `flush_interval_ms` is not a valid u32 |
