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
```

### `[database]` — Persistence and Timing

Controls how jobs and rules are stored and when they are evaluated.

```toml
[database]
fsync_on_persist = true
framerate = 512
logfile_path = "logfile"
```

**Options:**

| Option | Type | Default | Notes |
|--------|------|---------|-------|
| `fsync_on_persist` | boolean | `true` | Flush writes to disk immediately (safer, slower) |
| `framerate` | integer | `512` | Evaluation frequency in Hz (valid range: 1-65535) |
| `logfile_path` | string | `"logfile"` | Path to the binary logfile for job/rule persistence |

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

## Full Configuration Example

```toml
[log]
level = "info"

[controller]
listen = "127.0.0.1:5678"

[database]
fsync_on_persist = true
framerate = 512
logfile_path = "logfile"
```

## Default Configuration

If no configuration file is provided, ztick uses these defaults:

```toml
[log]
level = "info"

[controller]
listen = "127.0.0.1:5678"

[database]
fsync_on_persist = true
framerate = 512
logfile_path = "logfile"
```

## Configuration Best Practices

### Development

```toml
[log]
level = "debug"

[controller]
listen = "127.0.0.1:5678"

[database]
fsync_on_persist = true
framerate = 512
```

- Higher verbosity for debugging
- Default evaluation rate
- Safe persistence

### Production

```toml
[log]
level = "warn"

[controller]
listen = "0.0.0.0:5678"

[database]
fsync_on_persist = true
framerate = 512
```

- Minimal logging (errors and warnings only)
- Listen on all interfaces for distributed clients
- Safe persistence

### High-Volume

```toml
[log]
level = "error"

[controller]
listen = "0.0.0.0:5678"

[database]
fsync_on_persist = false
framerate = 1000
```

- Errors only
- Higher evaluation frequency
- Relaxed persistence (batch writes)

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
