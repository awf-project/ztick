# Protocol Reference

The ztick protocol is a simple line-based text protocol for communicating with the scheduler over TCP.

## Protocol Overview

- **Transport**: TCP
- **Format**: Newline-terminated lines
- **Parser**: Space-separated arguments with quoted string support
- **Max line size**: 4096 bytes (fixed per-connection buffer)

## Connection

```
1. Connect to the TCP server (default: 127.0.0.1:5678)
2. Send commands as lines (terminated with \n)
3. Receive responses (also newline-terminated)
4. Connection stays open for multiple commands
5. Close when done
```

## Command Format

Every command follows this structure:

```
<request_id> <instruction> <args...>\n
```

- `request_id` — A client-chosen identifier echoed back in the response (e.g., `req-1`, `cmd-42`)
- `instruction` — The operation to perform (`SET`, `GET`, or `RULE SET`)
- `args` — Instruction-specific arguments

## Response Format

```
<request_id> <status>\n
<request_id> <status> <body>\n
```

| Status | Meaning |
|--------|---------|
| `OK` | Command succeeded |
| `ERROR` | Command failed (e.g., storage error) |

The `request_id` matches the one sent in the command, allowing clients to correlate responses.

Write commands (`SET`, `RULE SET`) return a status-only response. Read commands (`GET`) return a response with additional data in the body after the status.

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Malformed line (invalid syntax) | Silently skipped, no response sent, connection stays open |
| Incomplete line (no newline yet) | Server waits for more data |
| Unrecognized command | Silently ignored, no response sent (see below) |
| Out of memory | Connection closed |

**Important**: Only `SET`, `GET`, and `RULE SET` produce responses. If you send an unrecognized command, the server will not send any response — the client must not block waiting for one.

## Commands

### SET

Create or update a job.

**Syntax**:
```
<request_id> SET <job_identifier> <timestamp>
```

**Parameters**:
- `job_identifier` (string): Unique job identifier (e.g., `backup.daily`)
- `timestamp`: Either an integer in nanoseconds or a datetime string `YYYY-MM-DD HH:MM:SS`

**Examples**:
```bash
# With nanosecond timestamp
echo 'req-1 SET backup.daily 1711612800000000000' | socat - TCP:localhost:5678
# Response: req-1 OK

# With datetime string
echo 'req-2 SET app.task.1 2026-03-30 14:00:00' | socat - TCP:localhost:5678
# Response: req-2 OK
```

### GET

Retrieve a job's current state.

**Syntax**:
```
<request_id> GET <job_identifier>
```

**Parameters**:
- `job_identifier` (string): The job identifier to look up (e.g., `backup.daily`)

**Response**:
- Success: `<request_id> OK <status> <execution_ns>\n`
- Not found: `<request_id> ERROR\n`

| Field | Description |
|-------|-------------|
| `status` | Job status: `planned`, `triggered`, `executed`, or `failed` |
| `execution_ns` | Execution timestamp in nanoseconds since Unix epoch |

**Examples**:
```bash
# Get a job's state
echo 'req-5 GET backup.daily' | socat - TCP:localhost:5678
# Response: req-5 OK planned 1711612800000000000

# Get a nonexistent job
echo 'req-6 GET no.such.job' | socat - TCP:localhost:5678
# Response: req-6 ERROR
```

**Notes**: GET is a read-only command — it does not generate any persistence log entry.

### RULE SET

Create or update a rule that matches jobs by prefix and assigns a runner.

**Syntax (shell runner)**:
```
<request_id> RULE SET <rule_identifier> <pattern> shell <command>
```

**Syntax (amqp runner)**:
```
<request_id> RULE SET <rule_identifier> <pattern> amqp <dsn> <exchange> <routing_key>
```

**Parameters**:
- `rule_identifier` (string): Unique rule identifier (e.g., `rule.backup`)
- `pattern` (string): Prefix to match job identifiers (e.g., `backup.` matches `backup.daily`)
- `shell <command>`: Execute a shell command when the job triggers. Quote the command if it contains spaces (e.g., `shell "/bin/echo hello"`)
- `amqp <dsn> <exchange> <routing_key>`: Publish to an AMQP broker (deferred — not yet operational)

**Examples**:
```bash
# Shell runner
echo 'req-3 RULE SET rule.backup backup. shell /usr/bin/backup.sh' | socat - TCP:localhost:5678
# Response: req-3 OK

# AMQP runner
echo 'req-4 RULE SET rule.notify notify. amqp amqp://broker:5672 jobs notifications' | socat - TCP:localhost:5678
# Response: req-4 OK
```

## Pattern Matching

Rules match jobs by **prefix**: a rule with pattern `backup.` matches any job whose identifier starts with `backup.` (e.g., `backup.daily`, `backup.weekly`).

When multiple rules match a job, the rule with the longest matching pattern wins.

## String Parsing

Arguments are space-separated. Quoted strings preserve spaces:

```
req-1 RULE SET rule.1 app. shell "/usr/bin/command --arg 'value'"
                            ├────────────────────────────────────┘
                            └─ Entire quoted string is one argument
```

Escaping inside quoted strings:
- `\"` → `"`
- `\\` → `\`

## Unimplemented Commands

The following commands are **not yet implemented**. The server silently ignores them — no response is sent and the connection remains open:
- `QUERY` — List jobs matching a pattern
- `REMOVE` — Delete a job
- `REMOVERULE` — Delete a rule
- `LISTRULES` — List all rules

## Examples

### Full Session

```bash
# Create a rule for backup jobs
echo 'r1 RULE SET rule.backup backup. shell /usr/bin/backup.sh' | socat - TCP:localhost:5678
# r1 OK

# Schedule a backup job for a specific datetime
echo 'r2 SET backup.daily 2026-03-30 02:00:00' | socat - TCP:localhost:5678
# r2 OK

# Schedule another job with nanosecond timestamp
echo 'r3 SET backup.weekly 1711872000000000000' | socat - TCP:localhost:5678
# r3 OK

# Retrieve the job's state
echo 'r4 GET backup.daily' | socat - TCP:localhost:5678
# r4 OK planned 1743303600000000000
```

### Batch Operations

```bash
{
  echo 'r1 RULE SET rule.jobs job. shell "/bin/echo done"'
  echo 'r2 SET job.1 2026-03-30 12:00:00'
  echo 'r3 SET job.2 2026-03-30 13:00:00'
  echo 'r4 SET job.3 2026-03-30 14:00:00'
} | socat - TCP:localhost:5678
```

Each command returns its own response:
```
r1 OK
r2 OK
r3 OK
r4 OK
```

### Python Client

```python
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('localhost', 5678))

# Create a rule
sock.send(b'r1 RULE SET rule.app app. shell "/bin/echo hello"\n')
print(sock.recv(1024).decode())  # r1 OK

# Schedule a job
sock.send(b'r2 SET app.task.1 2026-03-30 14:00:00\n')
print(sock.recv(1024).decode())  # r2 OK

sock.close()
```
