# Protocol Reference

The ztick protocol is a simple line-based text protocol for communicating with the scheduler over TCP.

## Protocol Overview

- **Transport**: TCP (plaintext or TLS-encrypted)
- **Format**: Newline-terminated lines
- **Parser**: Space-separated arguments with quoted string support
- **Max line size**: 4096 bytes (fixed per-connection buffer)

**TLS Support:** When ztick is configured with TLS certificates, the protocol is transparently encrypted over the same TCP connection. The protocol itself is unchanged — clients using TLS need only change their connection mechanism (e.g., use `openssl s_client` instead of `nc`). See [Configuration Reference](configuration.md) for TLS setup.

## Connection

```
1. Connect to the TCP server (default: 127.0.0.1:5678)
2. If TLS is configured, complete the TLS handshake
3. Send commands as lines (terminated with \n)
4. Receive responses (also newline-terminated)
5. Connection stays open for multiple commands
6. Close when done
```

When TLS is enabled, plaintext clients that connect will have their connection closed after a failed handshake. The server remains available to new connections.

## Command Format

Every command follows this structure:

```
<request_id> <instruction> <args...>\n
```

- `request_id` — A client-chosen identifier echoed back in the response (e.g., `req-1`, `cmd-42`)
- `instruction` — The operation to perform (`SET`, `GET`, `QUERY`, `LISTRULES`, `REMOVE`, `REMOVERULE`, or `RULE SET`)
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

Write commands (`SET`, `RULE SET`) and delete commands (`REMOVE`, `REMOVERULE`) return a status-only response. Read commands (`GET`) return a response with additional data in the body after the status. List commands (`QUERY`, `LISTRULES`) return multiple lines followed by a terminal `OK` line.

## Error Handling

| Condition | Behavior |
|-----------|----------|
| Malformed line (invalid syntax) | Silently skipped, no response sent, connection stays open |
| Incomplete line (no newline yet) | Server waits for more data |
| Unrecognized command | Silently ignored, no response sent (see below) |
| Out of memory | Connection closed |

**Important**: Only `SET`, `GET`, `QUERY`, `LISTRULES`, `REMOVE`, `REMOVERULE`, and `RULE SET` produce responses. If you send an unrecognized command, the server will not send any response — the client must not block waiting for one.

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

### QUERY

List jobs matching a prefix pattern, or all jobs when no pattern is given.

**Syntax**:
```
<request_id> QUERY [<pattern>]
```

**Parameters**:
- `pattern` (string, optional): Prefix to match against job identifiers. When omitted, returns all jobs.

**Response**:
- One line per matching job: `<request_id> <job_id> <status> <execution_ns>\n`
- Terminal line: `<request_id> OK\n`

| Field | Description |
|-------|-------------|
| `job_id` | The matching job's identifier |
| `status` | Job status: `planned`, `triggered`, `executed`, or `failed` |
| `execution_ns` | Execution timestamp in nanoseconds since Unix epoch |

**Examples**:
```bash
# Query all jobs with "backup." prefix
echo 'req-1 QUERY backup.' | socat - TCP:localhost:5678
# Response:
# req-1 backup.daily planned 1711612800000000000
# req-1 backup.weekly planned 1711872000000000000
# req-1 OK

# Query all jobs (no pattern)
echo 'req-2 QUERY' | socat - TCP:localhost:5678
# Response: one line per job, followed by req-2 OK

# Query with no matches
echo 'req-3 QUERY nonexistent.' | socat - TCP:localhost:5678
# Response:
# req-3 OK
```

**Notes**: QUERY is a read-only command — it does not generate any persistence log entry. Results are returned in unspecified order (hashmap iteration order).

### LISTRULES

List all configured rules.

**Syntax**:
```
<request_id> LISTRULES
```

**Parameters**: None. Extra trailing arguments are silently ignored.

**Response**:
- One line per rule: `<request_id> <rule_id> <pattern> <runner_type> <runner_args...>\n`
- Terminal line: `<request_id> OK\n`

| Field | Description |
|-------|-------------|
| `rule_id` | The rule's identifier |
| `pattern` | Prefix pattern the rule matches against |
| `runner_type` | Runner type: `shell` or `amqp` |
| `runner_args` | Shell: `<command>`. AMQP: `<dsn> <exchange> <routing_key>` |

**Examples**:
```bash
# List all rules (with shell and amqp rules loaded)
echo 'req-1 LISTRULES' | socat - TCP:localhost:5678
# Response:
# req-1 rule.backup backup. shell /usr/bin/backup.sh
# req-1 rule.notify notify. amqp amqp://broker:5672 jobs notifications
# req-1 OK

# List rules when none are loaded
echo 'req-2 LISTRULES' | socat - TCP:localhost:5678
# Response:
# req-2 OK

# Extra arguments are ignored
echo 'req-3 LISTRULES foo' | socat - TCP:localhost:5678
# Response: same as LISTRULES without arguments
```

**Notes**: LISTRULES is a read-only command — it does not generate any persistence log entry. Results are returned in unspecified order (hashmap iteration order).

### REMOVE

Delete a scheduled job.

**Syntax**:
```
<request_id> REMOVE <job_identifier>
```

**Parameters**:
- `job_identifier` (string): The job identifier to delete (e.g., `backup.daily`)

**Response**:
- Success: `<request_id> OK\n`
- Not found: `<request_id> ERROR\n`

**Examples**:
```bash
# Remove an existing job
echo 'req-7 REMOVE backup.daily' | socat - TCP:localhost:5678
# Response: req-7 OK

# Remove a nonexistent job
echo 'req-8 REMOVE no.such.job' | socat - TCP:localhost:5678
# Response: req-8 ERROR
```

**Notes**: REMOVE persists the deletion to the append-only logfile. The removal survives server restarts and background log compression.

### REMOVERULE

Delete an execution rule.

**Syntax**:
```
<request_id> REMOVERULE <rule_identifier>
```

**Parameters**:
- `rule_identifier` (string): The rule identifier to delete (e.g., `rule.backup`)

**Response**:
- Success: `<request_id> OK\n`
- Not found: `<request_id> ERROR\n`

**Examples**:
```bash
# Remove an existing rule
echo 'req-9 REMOVERULE rule.backup' | socat - TCP:localhost:5678
# Response: req-9 OK

# Remove a nonexistent rule
echo 'req-10 REMOVERULE no.such.rule' | socat - TCP:localhost:5678
# Response: req-10 ERROR
```

**Notes**: REMOVERULE persists the deletion to the append-only logfile. The removal survives server restarts and background log compression. Removing a rule does not cancel pending jobs that were previously matched by the rule.

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

# Query all backup jobs
echo 'r5 QUERY backup.' | socat - TCP:localhost:5678
# r5 backup.daily planned 1743303600000000000
# r5 backup.weekly planned 1711872000000000000
# r5 OK

# List all configured rules
echo 'r6 LISTRULES' | socat - TCP:localhost:5678
# r6 rule.backup backup. shell /usr/bin/backup.sh
# r6 OK

# Remove the weekly backup job
echo 'r7 REMOVE backup.weekly' | socat - TCP:localhost:5678
# r7 OK

# Remove the backup rule
echo 'r8 REMOVERULE rule.backup' | socat - TCP:localhost:5678
# r8 OK
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

# Query jobs by prefix
sock.send(b'r3 QUERY app.\n')
print(sock.recv(4096).decode())
# r3 app.task.1 planned 1743350400000000000
# r3 OK

# List all rules
sock.send(b'r4 LISTRULES\n')
print(sock.recv(4096).decode())
# r4 rule.app app. shell /bin/echo hello
# r4 OK

sock.close()
```
