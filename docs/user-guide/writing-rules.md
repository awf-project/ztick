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

The command is passed to the configured shell (default: `/bin/sh -c`), so shell features work. The shell binary and arguments can be changed via the `[shell]` config section — see [Configuration Reference](../reference/configuration.md#shell). Quote commands that contain spaces:

```bash
echo 'r1 RULE SET rule.complex complex. shell /usr/local/bin/my-script.sh' | socat - TCP:localhost:5678
```

### Direct Runner

Execute a command directly without shell interpretation. Useful for simple commands where you want to avoid shell injection vulnerabilities.

```bash
echo 'r1 RULE SET rule.fetch fetch. direct /usr/bin/curl -s http://example.com' | socat - TCP:localhost:5678
```

**Characteristics:**
- No shell interpreter involved — execve is used directly
- First argument is the executable path; remaining arguments are passed literally
- Shell metacharacters (`$()`, `;`, `|`, etc.) are passed as literal strings, not interpreted
- Eliminates shell injection risks

**Example: Safe from Injection**

```bash
# Shell runner: vulnerable to injection via job ID manipulation
echo 'r1 RULE SET rule.app1 app. shell "curl http://api/result?id=$1"' | socat - TCP:localhost:5678

# Direct runner: same command, immune to injection
echo 'r1 RULE SET rule.app2 app. direct /usr/bin/curl http://api/result?id=$1' | socat - TCP:localhost:5678
```

In the direct runner, `$1` is passed literally to curl as a query parameter value, not substituted by the shell.

### HTTP Runner

Trigger an external webhook via HTTP/HTTPS request. Useful for integrating ztick with third-party services like Slack, cloud functions, or custom webhooks.

```bash
echo 'r1 RULE SET rule.webhook deploy. http POST https://hooks.example.com/webhook' | socat - TCP:localhost:5678
```

**Characteristics**:
- Methods: `GET`, `POST`, `PUT`, `DELETE`
- POST and PUT requests include a JSON body: `{"job_id":"<identifier>","execution":<timestamp_ns>}`
- GET and DELETE requests send no body
- HTTP 2xx status codes are treated as success; all others as failure
- TLS is automatically used for `https://` URLs
- Connection and read timeouts: 30 seconds

**Example: Slack Webhook (POST)**

```bash
echo 'r1 RULE SET rule.slack-notify deploy. http POST https://hooks.slack.com/services/YOUR/WEBHOOK/URL' | socat - TCP:localhost:5678
```

When a job matching `deploy.*` triggers, ztick sends:
```
POST https://hooks.slack.com/services/YOUR/WEBHOOK/URL HTTP/1.1
Host: hooks.slack.com
Content-Type: application/json
Content-Length: 42

{"job_id":"deploy.v1.2.3","execution":1711612800000000000}
```

**Example: Health Check (GET)**

```bash
echo 'r1 RULE SET rule.health health. http GET https://api.internal/health' | socat - TCP:localhost:5678
```

GET requests send no body, useful for pinging endpoints.

**Example: PUT Request**

```bash
echo 'r1 RULE SET rule.update config. http PUT https://config.internal/update' | socat - TCP:localhost:5678
```

PUT requests also include the JSON body like POST.

### AWF Runner

Execute an AWF (AI Workflow) using the AWF CLI. Useful for automating AI agent pipelines (code review, report generation, data analysis) on a schedule.

```bash
echo 'r1 RULE SET rule.review code-review. awf code-review' | socat - TCP:localhost:5678
```

**Characteristics**:
- Workflow name is passed to `awf run <workflow>`
- Optional key=value input parameters via repeated `--input` flag
- Exit code 0 is success; non-zero is failure
- Requires `awf` CLI binary to be in `$PATH`

**Example: Without Inputs**

```bash
echo 'r1 RULE SET rule.review code-review. awf code-review' | socat - TCP:localhost:5678
# Response: r1 OK
```

Spawns: `awf run code-review`

**Example: With Inputs**

```bash
echo 'r1 RULE SET rule.report report. awf generate-report --input format=pdf --input target=main' | socat - TCP:localhost:5678
# Response: r1 OK
```

Spawns: `awf run generate-report --input format=pdf --input target=main`

Each `--input` flag passes one key=value pair. Repeat the flag for multiple parameters.

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

# 2. Verify rules are loaded
echo 'r3 LISTRULES' | socat - TCP:localhost:5678

# 3. Schedule jobs
echo 'r4 SET backup.daily 2026-04-01 02:00:00' | socat - TCP:localhost:5678
echo 'r5 SET backup.weekly 2026-04-07 03:00:00' | socat - TCP:localhost:5678
echo 'r6 SET report.monthly 2026-04-01 06:00:00' | socat - TCP:localhost:5678
```

When each job's execution time arrives:
- `backup.daily` and `backup.weekly` trigger `/usr/bin/backup.sh`
- `report.monthly` triggers `/usr/bin/generate-report.sh`

## Removing a Rule

Use the `REMOVERULE` command to delete a rule:

```bash
echo 'r1 REMOVERULE rule.backup' | socat - TCP:localhost:5678
```

Response:
```
r1 OK
```

If the rule doesn't exist:
```
r1 ERROR
```

REMOVERULE persists the deletion to the logfile — the rule stays removed across server restarts and background compression. Removing a rule does **not** cancel pending jobs that were previously matched by it.

## Listing Rules

Use `LISTRULES` to see all configured rules:

```bash
echo 'r1 LISTRULES' | socat - TCP:localhost:5678
```

Response (one line per rule, then `OK`):
```
r1 rule.backup backup. shell /usr/bin/backup.sh
r1 rule.report report. shell /usr/bin/generate-report.sh
r1 OK
```

If no rules are loaded, the response is just `r1 OK`. Rules are returned in unspecified order.

See [Protocol Reference](../reference/protocol.md#listrules) for full details.

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
