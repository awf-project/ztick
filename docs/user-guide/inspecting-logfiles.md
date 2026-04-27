---
title: "Inspecting Logfiles"
---

Guide to offline inspection and debugging of ztick's binary persistence logfiles.

## Overview

ztick persists all mutations (jobs, rules, removals) to a binary logfile. The `dump` command reads this logfile and outputs the contents in human-readable form, enabling offline debugging and audit trail review without requiring a running ztick instance.

## Basic Usage

### View All Entries (Text Format)

```bash
ztick dump /path/to/logfile
```

Prints every persisted entry as one line in text format matching the protocol command syntax:

```
SET job1 1711612800000000000 planned
RULE SET rule1 job1.* shell /bin/echo done
REMOVE job1
REMOVERULE rule1
```

### View All Entries (JSON Format)

```bash
ztick dump /path/to/logfile --format json
```

Prints one JSON object per line (NDJSON):

```json
{"type":"set","identifier":"job1","execution":1711612800000000000,"status":"planned"}
{"type":"rule_set","identifier":"rule1","pattern":"job1.*","runner":{"type":"shell","command":"/bin/echo done"}}
{"type":"remove","identifier":"job1"}
{"type":"remove_rule","identifier":"rule1"}
```

NDJSON output is ideal for piping to `jq` for filtering and transformation:

```bash
# Show only SET entries
ztick dump /path/to/logfile --format json | jq 'select(.type=="set")'

# Count entries by type
ztick dump /path/to/logfile --format json | jq -r '.type' | sort | uniq -c

# Extract all rule patterns
ztick dump /path/to/logfile --format json | jq 'select(.type=="rule_set") | .pattern'
```

## Compact Mode

### View Effective State Only

```bash
ztick dump /path/to/logfile --compact
```

Deduplicates entries and omits removals, showing only the final effective state — i.e., the state the scheduler would reconstruct on startup:

```
SET job1 1711612800000000000 planned
RULE SET rule1 job1.* shell /bin/echo done
```

If a job is created and then removed, it won't appear in compact output. Similarly, if a job is created multiple times, only the latest state is shown.

### Combine Compact with JSON

```bash
ztick dump /path/to/logfile --compact --format json
```

Outputs deduplicated entries in NDJSON format, useful for external analysis or auditing the current state without the mutation history.

## Live Tail

### Watch for New Entries

```bash
ztick dump /path/to/logfile --follow
```

Prints all existing entries first, then watches the logfile for newly appended data and prints new entries as they arrive. This is useful for real-time monitoring during incident response or live debugging while ztick is running.

Exit with `Ctrl+C` (SIGINT) or send SIGTERM — the process exits cleanly with no error output.

### Live Tail with JSON Output

```bash
ztick dump /path/to/logfile --format json --follow | jq 'select(.type=="set")'
```

Combines live tailing with JSON filtering, enabling real-time monitoring pipelines. For example, watch only SET operations:

```bash
ztick dump /path/to/logfile --format json --follow | jq 'select(.type=="set")'
```

## Error Handling

### Missing File

```bash
$ ztick dump missing.bin
Error: No such file or directory
```

Exits with code 1. File must exist and be readable.

### Empty Logfile

```bash
$ ztick dump empty.bin
# (no output)
```

Exits with code 0.

### Partial Trailing Frame

If the logfile ends with an incomplete entry (truncated write from a crash):

```
# All complete entries printed, then warning to stderr:
WARNING: partial frame at byte offset 1234 (incomplete entry)
```

The command exits with code 0 — all successfully parsed entries are printed, incomplete trailing data is skipped.

## Common Tasks

### Audit Trail for a Specific Job

```bash
ztick dump /path/to/logfile --format json | jq 'select(.identifier=="my.job")'
```

Show all mutations (SET/REMOVE) for a specific job identifier.

### Compare States Before/After Restart

```bash
# Capture effective state before restart
ztick dump /path/to/logfile --compact --format json > state-before.jsonl

# Restart ztick, let it run for a while
ztick -c /etc/ztick.conf

# Capture effective state after restart
ztick dump /path/to/logfile --compact --format json > state-after.jsonl

# Compare
diff state-before.jsonl state-after.jsonl
```

### Monitor Rule Matches During Testing

```bash
# Terminal 1: Start ztick
ztick -c /etc/ztick.conf

# Terminal 2: Watch rule operations
ztick dump /path/to/logfile --follow --format json | jq 'select(.type=="rule_set")'

# Terminal 3: Send jobs to ztick
echo "SET test.job 1711612800000000000" | socat - TCP:localhost:5678
```

## Timestamps

Timestamps are stored as **nanoseconds since Unix epoch** (i64). To convert to a human-readable date:

```bash
# Convert nanoseconds to seconds, then to date
ztick dump /path/to/logfile --format json | jq '.execution / 1e9 | todate'

# Show with both timestamp and date
ztick dump /path/to/logfile --format json | jq '{execution: .execution, date: (.execution / 1e9 | todate)}'
```

## Performance

For logfiles up to 100MB, dump completes in under 5 seconds on typical hardware:

- Text output streams incrementally — memory usage is constant regardless of logfile size
- Compact mode loads all entries into memory for deduplication, but output time is proportional to the number of unique identifiers (not logfile size)
- Follow mode uses polling for portability, checking for new data every 100ms

## See Also

- **[Persistence Format](../reference/persistence.md)** — Binary logfile encoding details
- **[Configuration](configuration.md)** — Configuring logfile path and other settings
- **[Protocol](../reference/protocol.md)** — Protocol command syntax reference
