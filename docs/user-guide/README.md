# User Guide

Task-oriented how-to guides for common ztick operations.

## Topics

- **[Creating Jobs](creating-jobs.md)** — Define, schedule, and manage jobs
  - Basic job creation with `SET`
  - Job lifecycle and states
  - Removing jobs with `REMOVE`
  - Batch operations

- **[Writing Rules](writing-rules.md)** — Match jobs and specify actions
  - Pattern matching and priority (longest match wins)
  - Runner types (Shell)
  - Rule management and removal with `REMOVERULE`
  - Best practices

- **[Configuration](configuration.md)** — Customize behavior
  - Logging levels
  - TCP server settings
  - TLS encryption setup
  - Persistence and evaluation frequency

- **[Inspecting Logfiles](inspecting-logfiles.md)** — Dump and analyze the binary logfile
  - Human-readable text output
  - NDJSON export for `jq` pipelines
  - Compact mode for effective state
  - Live tail with `--follow`

- **[Monitoring Health](monitoring-health.md)** — Check server status and execution pipeline
  - Server health metrics with `STAT`
  - Understanding metric categories
  - Scripting health checks

## Quick Reference

### Create a Job

```bash
echo 'SET my.job 1234567890' | socat - TCP:localhost:5678
```

### Create a Rule

```bash
echo 'RULE SET my.job.* SHELL /bin/echo done' | socat - TCP:localhost:5678
```

### View a Job

```bash
echo 'GET my.job' | socat - TCP:localhost:5678
```

### Query Jobs

```bash
echo 'req-1 QUERY my.' | socat - TCP:localhost:5678
```

### Remove a Job

```bash
echo 'req-1 REMOVE my.job' | socat - TCP:localhost:5678
```

### Remove a Rule

```bash
echo 'req-1 REMOVERULE my.rule' | socat - TCP:localhost:5678
```

### List Rules

```bash
echo 'req-1 LISTRULES' | socat - TCP:localhost:5678
```

### Check Server Health

```bash
echo 'req-1 STAT' | socat - TCP:localhost:5678
```

### Inspect Logfile

```bash
ztick dump logfile                          # text output
ztick dump logfile --format json            # NDJSON output
ztick dump logfile --compact                # effective state only
ztick dump logfile --follow                 # live tail
```

## Common Tasks

### Schedule Daily Backup

1. Create a rule:
   ```bash
   echo 'RULE SET backup.daily SHELL /usr/bin/backup.sh' | socat - TCP:localhost:5678
   ```

2. Create jobs for each day:
   ```bash
   # Schedule for tomorrow at 2 AM
   TOMORROW_2AM=$(date -d "tomorrow 2:00" +%s)
   echo "SET backup.daily $TOMORROW_2AM" | socat - TCP:localhost:5678
   ```

### Route Jobs by Priority

Use rule weights to prioritize:

```bash
# Low priority catch-all
echo 'RULE SET * SHELL /bin/log-event 1' | socat - TCP:localhost:5678

# High priority critical jobs
echo 'RULE SET critical.* SHELL /bin/alert-admin 100' | socat - TCP:localhost:5678

# Medium priority
echo 'RULE SET important.* SHELL /bin/notify 50' | socat - TCP:localhost:5678
```

### Migrate from Another Scheduler

1. Export jobs/rules from the old system
2. Convert to ztick format (pattern: `SET identifier timestamp`)
3. Batch-import via script:
   ```bash
   while read line; do
     echo "$line" | socat - TCP:localhost:5678
   done < jobs.txt
   ```

## Troubleshooting

See the reference documentation and [Getting Started](../tutorials/getting-started.md#troubleshooting) for troubleshooting.
