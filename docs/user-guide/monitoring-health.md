---
title: "Monitoring Server Health"
---

The `STAT` command provides a real-time snapshot of server health metrics. Use it to verify the server is running correctly, detect connection leaks, and inspect the execution pipeline.

## Checking Server Status

```bash
echo 'req-1 STAT' | socat - TCP:localhost:5678
```

Response:

```
req-1 uptime_ns 60000000000
req-1 connections 1
req-1 jobs_total 42
req-1 jobs_planned 30
req-1 jobs_triggered 2
req-1 jobs_executed 8
req-1 jobs_failed 2
req-1 rules_total 5
req-1 executions_pending 0
req-1 executions_inflight 0
req-1 persistence logfile
req-1 compression idle
req-1 auth_enabled 0
req-1 tls_enabled 0
req-1 framerate 512
req-1 OK
```

## Understanding the Metrics

### Server State

| Metric | What It Tells You |
|--------|-------------------|
| `uptime_ns` | How long the server has been running (nanoseconds) |
| `connections` | Number of active TCP connections, including yours |
| `framerate` | Configured scheduler tick rate |

### Job Counts

| Metric | What It Tells You |
|--------|-------------------|
| `jobs_total` | Total jobs in storage |
| `jobs_planned` | Jobs waiting to trigger |
| `jobs_triggered` | Jobs that matched a rule and are queued |
| `jobs_executed` | Jobs that completed successfully |
| `jobs_failed` | Jobs that failed execution |

### Execution Pipeline

| Metric | What It Tells You |
|--------|-------------------|
| `executions_pending` | Jobs waiting in the execution queue |
| `executions_inflight` | Jobs currently being executed by the processor thread |
| `rules_total` | Number of configured rules |

A growing `executions_pending` value indicates the processor thread cannot keep up with triggered jobs.

### Infrastructure

| Metric | What It Tells You |
|--------|-------------------|
| `persistence` | Backend type: `logfile` (durable) or `memory` (ephemeral) |
| `compression` | Background compression status: `idle`, `running`, `success`, or `failure` |
| `auth_enabled` | `1` if authentication is configured |
| `tls_enabled` | `1` if TLS encryption is active |

## Scripting Health Checks

STAT returns metrics in a fixed order, making it reliable for scripting:

```bash
# Extract a specific metric
echo 'r1 STAT' | socat - TCP:localhost:5678 | grep 'r1 connections' | awk '{print $3}'

# Simple health check script
#!/bin/bash
response=$(echo 'hc STAT' | socat - TCP:localhost:5678 2>/dev/null)
if echo "$response" | grep -q 'hc OK'; then
    echo "Server is healthy"
else
    echo "Server unreachable"
    exit 1
fi
```

## Notes

- STAT is read-only — it does not write to the persistence logfile.
- STAT is namespace-independent — any authenticated client can call it.
- When authentication is enabled, STAT requires authentication like any other command.
- Extra arguments after `STAT` are silently ignored.
- See the [Protocol Reference](../reference/protocol.md#stat) for the full specification.
