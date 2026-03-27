# User Guide

Task-oriented how-to guides for common ztick operations.

## Topics

- **[Creating Jobs](creating-jobs.md)** — Define and schedule jobs
  - Basic job creation with `SET`
  - Job lifecycle and states
  - Batch operations

- **[Writing Rules](writing-rules.md)** — Match jobs and specify actions
  - Pattern matching and priority (weight)
  - Runner types (Shell, HTTP, AMQP)
  - Rule management and best practices

- **[Configuration](configuration.md)** — Customize behavior
  - Logging levels
  - TCP server settings
  - Persistence and evaluation frequency
  - Environment variable overrides

## Quick Reference

### Create a Job

```bash
echo 'SET my.job 1234567890' | nc localhost 5678
```

### Create a Rule

```bash
echo 'SETRULE my.job.* SHELL /bin/echo done' | nc localhost 5678
```

### View a Job

```bash
echo 'GET my.job' | nc localhost 5678
```

### Query Jobs

```bash
echo 'QUERY my.*' | nc localhost 5678
```

### List Rules

```bash
echo 'LISTRULES' | nc localhost 5678
```

## Common Tasks

### Schedule Daily Backup

1. Create a rule:
   ```bash
   echo 'SETRULE backup.daily SHELL /usr/bin/backup.sh' | nc localhost 5678
   ```

2. Create jobs for each day:
   ```bash
   # Schedule for tomorrow at 2 AM
   TOMORROW_2AM=$(date -d "tomorrow 2:00" +%s)
   echo "SET backup.daily $TOMORROW_2AM" | nc localhost 5678
   ```

### Route Jobs by Priority

Use rule weights to prioritize:

```bash
# Low priority catch-all
echo 'SETRULE * SHELL /bin/log-event 1' | nc localhost 5678

# High priority critical jobs
echo 'SETRULE critical.* SHELL /bin/alert-admin 100' | nc localhost 5678

# Medium priority
echo 'SETRULE important.* SHELL /bin/notify 50' | nc localhost 5678
```

### Migrate from Another Scheduler

1. Export jobs/rules from the old system
2. Convert to ztick format (pattern: `SET identifier timestamp`)
3. Batch-import via script:
   ```bash
   while read line; do
     echo "$line" | nc localhost 5678
   done < jobs.txt
   ```

## Troubleshooting

See the reference documentation and [Getting Started](../tutorials/getting-started.md#troubleshooting) for troubleshooting.
