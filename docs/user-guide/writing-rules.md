# Writing Rules

A **Rule** matches job identifiers by prefix and specifies what happens when a matching job triggers. This guide covers rule creation, pattern matching, and runner configuration.

## Basic Rule Creation

Use the `RULE SET` instruction:

```
<request_id> RULE SET <rule_identifier> <pattern> <runner_type> <runner_args...>
```

### Example: Shell Runner

```bash
echo 'r1 RULE SET rule.backup backup. shell /usr/local/bin/backup.sh' | socat - TCP:localhost:5678
```

Creates a rule that:
- Is identified as `rule.backup`
- Matches any job starting with `backup.` (e.g., `backup.daily`, `backup.hourly`)
- Executes `/usr/local/bin/backup.sh` when a matching job triggers

Response:
```
r1 OK
```

## Pattern Matching

Rules use **prefix matching**: the pattern is compared against the start of each job identifier.

### Prefix Match

```bash
echo 'r1 RULE SET rule.app app. shell /bin/process' | socat - TCP:localhost:5678
```

Matches: `app.task.1`, `app.job.2`, `app.anything`
Does not match: `application.task`, `my.app.task`

### Exact Match

Use the full identifier as pattern:

```bash
echo 'r1 RULE SET rule.reboot system.reboot shell /usr/bin/reboot' | socat - TCP:localhost:5678
```

Matches only: `system.reboot` (and anything starting with `system.reboot`)

### Multiple Rules

Create separate rules for different job families:

```bash
echo 'r1 RULE SET rule.backup backup. shell /usr/bin/backup.sh' | socat - TCP:localhost:5678
echo 'r2 RULE SET rule.db database. shell /usr/bin/db-sync.sh' | socat - TCP:localhost:5678
echo 'r3 RULE SET rule.mail mail. shell /usr/bin/mail-send.sh' | socat - TCP:localhost:5678
```

### Priority by Specificity

When multiple rules match a job, the rule with the **longest matching pattern** wins:

```bash
# Broad rule: matches all jobs starting with "app."
echo 'r1 RULE SET rule.app.general app. shell "/bin/echo general"' | socat - TCP:localhost:5678

# Specific rule: matches only "app.critical." jobs
echo 'r2 RULE SET rule.app.critical app.critical. shell /bin/alert' | socat - TCP:localhost:5678
```

Job `app.critical.task1` matches both patterns, but `app.critical.` is longer (14 chars vs 4 chars), so the alert rule wins.

## Runner Types

### Shell Runner

Execute a command in a child process:

```bash
echo 'r1 RULE SET rule.logs logs. shell "/usr/sbin/logrotate -f /etc/logrotate.conf"' | socat - TCP:localhost:5678
```

The command is passed to `/bin/sh -c`, so shell features work. Quote commands that contain spaces:

```bash
echo 'r1 RULE SET rule.complex complex. shell /usr/local/bin/my-script.sh' | socat - TCP:localhost:5678
```

### AMQP Runner (Deferred)

Publish a message to an AMQP broker. The AMQP runner is defined in the protocol but not yet operational.

```bash
echo 'r1 RULE SET rule.notify notify. amqp amqp://broker:5672 jobs notifications' | socat - TCP:localhost:5678
```

**Parameters**: `amqp <dsn> <exchange> <routing_key>`

## Updating a Rule

Overwrite a rule by sending RULE SET with the same identifier:

```bash
echo 'r1 RULE SET rule.backup backup. shell /usr/bin/backup-v2.sh' | socat - TCP:localhost:5678
```

## Complete Example

```bash
# 1. Create rules
echo 'r1 RULE SET rule.backup backup. shell /usr/bin/backup.sh' | socat - TCP:localhost:5678
echo 'r2 RULE SET rule.report report. shell /usr/bin/generate-report.sh' | socat - TCP:localhost:5678

# 2. Schedule jobs
echo 'r3 SET backup.daily 2026-04-01 02:00:00' | socat - TCP:localhost:5678
echo 'r4 SET backup.weekly 2026-04-07 03:00:00' | socat - TCP:localhost:5678
echo 'r5 SET report.monthly 2026-04-01 06:00:00' | socat - TCP:localhost:5678
```

When each job's execution time arrives:
- `backup.daily` and `backup.weekly` trigger `/usr/bin/backup.sh`
- `report.monthly` triggers `/usr/bin/generate-report.sh`

## Limitations

The following operations are **not yet implemented**:
- `LISTRULES` — List all rules
- `REMOVERULE` — Delete a rule

## Best Practices

### 1. Use Descriptive Identifiers and Patterns

```bash
# Clear
echo 'r1 RULE SET rule.backup.daily backup.daily. shell /usr/bin/daily-backup' | socat - TCP:localhost:5678

# Confusing
echo 'r1 RULE SET r1 bak shell /usr/bin/backup' | socat - TCP:localhost:5678
```

### 2. Create Rules Before Jobs

A job that triggers without a matching rule transitions to `failed`. Always set up rules first.

### 3. Make Scripts Idempotent

Rules may be retried if execution fails. Ensure commands are safe to run multiple times:

```bash
#!/bin/bash
set -euo pipefail
# Idempotent: safe to run multiple times
mkdir -p /var/backups
cp /data/important.db /var/backups/important.db.$(date +%s)
```

### 4. Test Commands Independently

Before creating a rule, verify the command works:

```bash
/usr/local/bin/backup.sh
echo $?  # Should be 0 for success
```
