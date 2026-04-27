---
title: "Creating Jobs"
---

A **Job** is a scheduled action with an execution timestamp. This guide shows you how to create and manage jobs.

## Basic Job Creation

Use the `SET` instruction in the ztick protocol:

```
<request_id> SET <identifier> <timestamp>
```

### Example

```bash
echo 'req-1 SET backup.daily 2026-04-01 02:00:00' | socat - TCP:localhost:5678
```

Creates a job with:
- **Identifier**: `backup.daily` (must be unique)
- **Execution time**: `2026-04-01 02:00:00`

Response:
```
req-1 OK
```

## Timestamp Formats

ztick accepts two timestamp formats:

### Datetime String

Two arguments in `YYYY-MM-DD HH:MM:SS` format:

```bash
echo 'r1 SET my.job 2026-04-01 14:30:00' | socat - TCP:localhost:5678
```

### Integer Nanoseconds

A single argument with nanoseconds since Unix epoch:

```bash
echo 'r1 SET my.job 1711612800000000000' | socat - TCP:localhost:5678
```

## Job Lifecycle

Every job transitions through states:

| State | Meaning |
|-------|---------|
| `planned` | Created but not yet due |
| `triggered` | Execution time reached, matched to a rule's runner |
| `executed` | Runner completed successfully |
| `failed` | Runner returned an error, or no matching rule was found |

A job without a matching rule will transition directly to `failed` when its execution time arrives.

## Job Identifiers

Identifiers are hierarchical strings separated by dots:

```
app.component.instance
backup.daily.001
system.maintenance.cache-clear
```

**Good practices:**
- Use lowercase letters, numbers, and dots
- Organize hierarchically (app -> component -> instance)
- Match your rule patterns (a rule with pattern `backup.` matches `backup.daily`)

## Scheduling Jobs Programmatically

### Python Client

```python
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('localhost', 5678))

# Schedule a job with datetime
sock.send(b'r1 SET my.job.1 2026-04-01 14:00:00\n')
response = sock.recv(1024).decode()
print(response)  # r1 OK

sock.close()
```

### Bash with Nanosecond Timestamp

```bash
# Current time in nanoseconds
TIMESTAMP=$(python3 -c "import time; print(int(time.time() * 1_000_000_000))")
echo "r1 SET my.job.1 $TIMESTAMP" | socat - TCP:localhost:5678
```

## Jobs and Rules

Jobs don't do anything by themselves — you need **Rules** that specify what happens when a matching job triggers.

Create a rule first, then schedule jobs:

```bash
# Create a rule matching all backup.* jobs
echo 'r1 RULE SET rule.backup backup. shell /usr/local/bin/backup.sh' | socat - TCP:localhost:5678

# Schedule a job
echo 'r2 SET backup.daily 2026-04-01 02:00:00' | socat - TCP:localhost:5678
```

When the execution time arrives, ztick runs `/usr/local/bin/backup.sh`.

See [Writing Rules](writing-rules.md) for details.

## Updating a Job

Overwrite a job by sending SET with the same identifier:

```bash
echo 'r1 SET my.job.1 2026-04-02 08:00:00' | socat - TCP:localhost:5678
```

This reschedules the job to a new execution time.

## Batch Operations

Create multiple jobs in one connection:

```bash
{
  echo 'r1 SET job.1 2026-04-01 08:00:00'
  echo 'r2 SET job.2 2026-04-01 09:00:00'
  echo 'r3 SET job.3 2026-04-01 10:00:00'
} | socat - TCP:localhost:5678
```

Each command returns its response:
```
r1 OK
r2 OK
r3 OK
```

## Checking Job State

Use the `GET` command to retrieve a job's current state:

```bash
echo 'r1 GET backup.daily' | socat - TCP:localhost:5678
```

Response for an existing job:
```
r1 OK planned 1743303600000000000
```

The response includes the job's status (`planned`, `triggered`, `executed`, `failed`) and execution timestamp in nanoseconds.

If the job doesn't exist:
```
r1 ERROR
```

GET is read-only — it does not affect persistence.

## Searching Jobs

Use the `QUERY` command to find jobs matching a prefix pattern, or list all jobs when no pattern is given:

```bash
# List all jobs starting with "backup."
echo 'r1 QUERY backup.' | socat - TCP:localhost:5678
```

Response:
```
r1 backup.daily planned 1743303600000000000
r1 backup.weekly planned 1743390000000000000
r1 OK
```

List all jobs (omit the pattern):

```bash
echo 'r1 QUERY' | socat - TCP:localhost:5678
```

QUERY is read-only — it does not generate persistence entries.


## Removing a Job

Use the `REMOVE` command to delete a scheduled job:

```bash
echo 'r1 REMOVE backup.daily' | socat - TCP:localhost:5678
```

Response:
```
r1 OK
```

If the job doesn't exist:
```
r1 ERROR
```

REMOVE persists the deletion to the logfile — the job stays removed across server restarts and background compression.

## Tips

- **Use clear identifiers**: `mail.send.welcome` is clearer than `msg.s.w`
- **Batch related jobs**: Group jobs by domain (backup.*, mail.*, etc.)
- **Create rules before jobs**: A job without a matching rule will fail when triggered
