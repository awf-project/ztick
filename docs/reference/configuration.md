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

**Persistence Modes:**
- `"logfile"` — (default) Store jobs and rules in an append-only binary logfile. Data persists across restarts. Use for production deployments where durability is critical.
- `"memory"` — Store jobs and rules only in memory. No disk I/O occurs. Data is lost on shutdown. Useful for ephemeral deployments, CI environments, and testing where durability is not required.

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
```

## Errors

| Error | Cause |
|-------|-------|
| `InvalidLogLevel` | `level` is not one of the valid values |
| `FramerateOutOfRange` | `framerate` is 0 |
| `UnknownSection` | Section name is not `log`, `controller`, or `database` |
| `UnknownKey` | Key is not recognized within its section |
| `InvalidValue` | Value cannot be parsed (e.g. non-boolean for `fsync_on_persist`), or only one of `tls_cert`/`tls_key` is set, or `persistence` is not `"logfile"` or `"memory"` |
