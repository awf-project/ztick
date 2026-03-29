# Reference

Technical specification and API documentation for ztick.

## Contents

- **[Configuration Schema](configuration.md)** — All TOML options and their defaults
- **[Protocol](protocol.md)** — Client communication format and commands
- **[Data Types](types.md)** — Core domain structures
- **[Persistence Format](persistence.md)** — Binary logfile encoding

## Quick Links

### Configuration

```toml
[log]
level = "info"                    # error, warn, info, debug

[controller]
listen = "127.0.0.1:5678"        # TCP server address

[database]
fsync_on_persist = true          # Flush on every write
framerate = 1                     # Evaluations per second
```

### Protocol

```
SET <id> <timestamp>                    # Create job
GET <id>                                # Retrieve job
QUERY <pattern>                         # List matching jobs
REMOVE <id>                             # Delete job

RULE SET <id> <pattern> <runner>        # Create rule
REMOVERULE <id>                         # Delete rule
LISTRULES                               # List all rules (not yet implemented)
```

### Data Types

| Type | Purpose | Example |
|------|---------|---------|
| **Job** | Scheduled action with timestamp | `app.backup.daily` at `1711612800` |
| **Rule** | Pattern match + runner mapping | `backup.*` → `SHELL /bin/backup.sh` |
| **Runner** | Execution target | `SHELL`, `HTTP`, `AMQP` |
| **Execution** | Job result (success/failure) | Tracking and logging |

### Persistence

- **Format**: Binary (length-prefixed entries)
- **Entries**: Job records, rule records, status updates
- **Encoding**: Big-endian integers, UTF-8 strings, i64 nanosecond timestamps

## See Also

- **[Getting Started](../tutorials/getting-started.md)** — Step-by-step setup
- **[User Guide](../user-guide/)** — How-to guides for common tasks
- **[Development](../development/)** — Architecture and contribution guidelines
