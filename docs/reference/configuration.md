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
| `level` | string | `"info"` | Log verbosity: `off`, `error`, `warn`, `info`, `debug`, `trace` |

**Levels**:
- `off` — No output (silent)
- `error` — Output errors only (most quiet)
- `warn` — Warnings and errors
- `info` — General information (recommended for production)
- `debug` — Detailed debugging output
- `trace` — Maximum verbosity (most verbose)

### `[controller]`

TCP server configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `listen` | string | `"127.0.0.1:5678"` | TCP address and port for the protocol server |

**Address Format**: `<host>:<port>` where host is IPv4 or IPv6
- `127.0.0.1:5678` — Localhost only
- `0.0.0.0:5678` — All interfaces (IPv4)
- `[::1]:5678` — Localhost only (IPv6)

### `[database]`

Persistence and scheduling configuration.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `fsync_on_persist` | bool | `true` | Call fsync after each persistence write (safer, slower) |
| `framerate` | integer | `512` | Scheduler tick rate in Hz (valid range: 1-65535) |

**Framerate**:
- `1` — Evaluate once per second (low CPU, long latency)
- `512` — Default, evaluate 512 times per second (~2ms latency)
- `1000` — Evaluate 1000 times per second (~1ms latency)

## Full Example

```toml
[log]
level = "debug"

[controller]
listen = "0.0.0.0:9000"

[database]
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
| `InvalidValue` | Value cannot be parsed (e.g. non-boolean for `fsync_on_persist`) |
