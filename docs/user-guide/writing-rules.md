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

### AMQP Runner

Publish a message to an AMQP 0-9-1 broker (e.g. RabbitMQ) when a matching job triggers. Useful for fanning out scheduled events to downstream consumers without coupling them to ztick.

```bash
echo 'r1 RULE SET rule.notify notify. amqp amqp://guest:guest@localhost:5672/ jobs notifications' | socat - TCP:localhost:5678
```

**Parameters**: `amqp <dsn> <exchange> <routing_key>`

**Characteristics**:
- AMQP 0-9-1 protocol over plaintext TCP (default port 5672)
- DSN format: `amqp://[user[:password]@]host[:port][/vhost]` — credentials are redacted from logs
- Each execution opens a new TCP connection, performs the handshake, publishes one `basic.publish` frame, then closes cleanly
- Message body is the job identifier (u128 hex string); richer payloads are a future addition
- Connect/send/receive timeout: 30 seconds — broker latency cannot starve the processor thread
- Fire-and-forget: success means the publish frame was accepted by the broker at TCP level (no publisher confirms in v1)
- Connection refused, authentication failure, or malformed DSN return `success = false` without crashing the processor

**Limitations**:
- TLS (`amqps://`) is not supported — use a stunnel sidecar or wait for a future revision if you need encryption in transit
- Exchange existence is not validated; if the exchange is missing the broker silently drops the message (consult RabbitMQ logs)
- No connection pooling — each execution pays a fresh handshake (~10 ms on localhost)

**Example: Notify on Deploy**

```bash
echo 'r1 RULE SET rule.deploy deploy. amqp amqp://guest:guest@rabbitmq:5672/ jobs deploy.events' | socat - TCP:localhost:5678
```

When a job matching `deploy.*` triggers, ztick publishes the job identifier to exchange `jobs` with routing key `deploy.events`.

**Local Development Stack**

A `compose.yaml` at the repository root boots a RabbitMQ broker with the management UI on `http://localhost:15672` (default credentials `guest` / `guest`):

```bash
docker compose up -d
```

**Prepare the broker (declare exchange / queue / binding)**

ztick publishes to whatever exchange + routing-key the rule names. RabbitMQ accepts the publish at TCP level even when no queue is bound (without publisher confirms — see the *Limitations* above), so messages disappear silently if the topology is missing. Declare it once before sending real traffic.

Using the bundled CLI (RabbitMQ 4.x — note the `--name` flag syntax, **not** the legacy `name=value`):

```bash
docker compose exec rabbitmq rabbitmqadmin declare exchange --name jobs --type direct --durable true
docker compose exec rabbitmq rabbitmqadmin declare queue --name notifications --durable true
docker compose exec rabbitmq rabbitmqadmin declare binding --source jobs --destination notifications --destination-type queue --routing-key notifications
```

The shorthand alternative is to publish to the *default exchange* (`""`) with the routing key set to the queue name — RabbitMQ then routes directly to that queue, no binding needed:

```bash
docker compose exec rabbitmq rabbitmqadmin declare queue --name ztick.events --durable true
# Then in the rule: amqp amqp://guest:guest@localhost:5672/ "" ztick.events
```

The management UI on `http://localhost:15672` exposes the same actions under the *Exchanges* and *Queues* tabs.

**Verifying messages arrive**

Without publisher confirms, ztick reports `success = true` as soon as the publish frame leaves the socket — the broker may still drop the message if no queue is bound. Two cheap ways to confirm receipt:

```bash
# Drain one message (acknowledges and removes it from the queue)
docker compose exec rabbitmq rabbitmqadmin get messages --queue notifications --count 1

# Or watch the queue depth without consuming
watch -n 1 'docker compose exec rabbitmq rabbitmqadmin list queues name messages'
```

The management UI's *Queues → notifications → Get messages* (with *Ack mode = Reject requeue true*) inspects without draining.

A successful publish from ztick produces a body equal to the job identifier formatted as a u128 hex string, for example:

```
Body: 0x1a2b3c4d5e6f70809a0b1c2d3e4f5a6b
```

Consumers should treat the body as opaque text and look up the job's actual data via ztick's TCP `GET <job_id>` if richer context is needed.

**Troubleshooting**

The runner never propagates errors to the processor — every failure path returns `success = false` and emits one warning to stderr (with the DSN credentials stripped). Map the warning text to the likely cause:

| Warning line | Likely cause | Fix |
|---|---|---|
| `amqp runner: dsn parse failed: ... err=error.InvalidScheme` | DSN does not start with `amqp://`, or uses `amqps://` (TLS not supported) | Correct the scheme; remove `s` suffix |
| `amqp runner: dsn parse failed: ... err=error.MissingUserInfo` | DSN omits the `@` separator (e.g. `amqp://host/`) | Add credentials, even `guest:guest@` |
| `amqp runner: dsn parse failed: ... err=error.MissingHost` | Empty host (e.g. `amqp://user:pass@:5672/`) | Provide a hostname or IP |
| `amqp runner: dsn parse failed: ... err=error.InvalidPort` | Port is non-numeric or > 65535 | Fix the port |
| `amqp runner: tcp connect failed: ... err=error.ConnectionRefused` | Broker is not listening on that host:port | `docker compose ps`; check `[http]` is on the right port; firewall |
| `amqp runner: tcp connect failed: ... err=error.ConnectionTimedOut` | Broker reachable but slow to accept (overload, network); 30 s timeout exhausted | Investigate broker health; consider raising broker resources |
| `amqp runner: handshake failed: ... err=error.PeerClose` | Broker closed the connection during handshake — almost always authentication failure (AMQP reply-code 403) | Verify credentials in the DSN; check broker user permissions |
| `amqp runner: handshake failed: ... err=error.EndOfStream` | Broker closed mid-handshake without sending Connection.Close (rare) | Check broker logs for protocol errors |

If the publish *appears* to succeed (no warning) but the queue stays empty, the topology is the suspect — see *Prepare the broker* and *Verifying messages arrive* above.

### Redis Runner

Send a single Redis command to a Redis server when a matching job triggers. Useful for fanning out events on a pub/sub channel or pushing job identifiers onto a Redis-backed worker queue without deploying a heavyweight broker.

```bash
echo 'r1 RULE SET rule.publish deploy. redis redis://127.0.0.1:6379/0 PUBLISH deploy:events' | socat - TCP:localhost:5678
```

**Parameters**: `redis <url> <command> <key>`

**Characteristics**:
- Plaintext RESP2 over TCP (default port 6379)
- URL format: `redis://[user[:password]@]host[:port][/db]` — credentials are redacted from logs
- Allowed commands (case-sensitive, validated at `RULE SET` parse time): `PUBLISH`, `RPUSH`, `LPUSH`, `SET`
- Each execution opens a new TCP connection, optionally sends `AUTH` (single-arg or ACL two-arg form), optionally sends `SELECT <db>` when `db != 0`, sends the configured command with the job identifier as the value/payload, then closes
- Connect/send/receive timeout: 30 seconds — Redis latency cannot starve the processor thread
- Fire-and-forget: `PUBLISH` with zero subscribers is treated as success (matches `redis-cli` defaults); a RESP error reply (`-ERR ...`) is treated as failure
- Connection refused, auth rejection, malformed URL, or unsupported commands return `success = false` without crashing the processor

**Limitations**:
- TLS (`rediss://`) is not supported — rejected at parse time. Wait for the general TLS-support track if you need encryption in transit
- Only `PUBLISH`, `RPUSH`, `LPUSH`, `SET` are supported in v1 (no `HSET`, `SADD`, `XADD`, etc.)
- No connection pooling — each execution pays a fresh handshake (~1 ms on localhost)
- Payload is the raw job identifier; structured JSON envelopes are deferred

**Example: Publish on Deploy (PUBLISH)**

```bash
echo 'r1 RULE SET rule.publish deploy. redis redis://127.0.0.1:6379/0 PUBLISH deploy:events' | socat - TCP:localhost:5678
```

When a job matching `deploy.*` triggers, ztick connects to Redis and runs `PUBLISH deploy:events <job_id>`. Subscribers on the `deploy:events` channel receive the job identifier as the message payload.

Verify the channel locally:

```bash
# In one terminal: subscribe
docker compose exec redis redis-cli SUBSCRIBE deploy:events

# In another terminal: schedule a matching job
echo 'r2 SET deploy.release.v1 2026-04-27 12:00:00' | socat - TCP:localhost:5678
```

**Example: Worker Queue (RPUSH)**

```bash
echo 'r1 RULE SET rule.queue backup. redis redis://127.0.0.1:6379/0 RPUSH backup:tasks' | socat - TCP:localhost:5678
```

When a job matching `backup.*` triggers, ztick runs `RPUSH backup:tasks <job_id>`, appending the job identifier to the tail of the `backup:tasks` list. Workers can drain the list with `BLPOP backup:tasks 0`.

Verify the queue:

```bash
# Inspect the list contents (does not consume)
docker compose exec redis redis-cli LRANGE backup:tasks 0 -1

# Pop the next task (consumes)
docker compose exec redis redis-cli LPOP backup:tasks
```

**Example: Authenticated Redis with Non-Zero Database**

```bash
echo 'r1 RULE SET rule.notify notify. redis redis://app:s3cr3t@redis.internal:6379/3 PUBLISH notify:events' | socat - TCP:localhost:5678
```

Triggers send `AUTH app s3cr3t`, then `SELECT 3`, then `PUBLISH notify:events <job_id>`. When the URL contains only a password (`redis://:s3cr3t@host/0`), ztick falls back to the legacy single-arg `AUTH s3cr3t`.

**Local Development Stack**

The bundled `compose.yaml` boots a Redis service on `127.0.0.1:6379` with no auth and database `0`:

```bash
docker compose up -d redis
docker compose exec redis redis-cli ping
# PONG
```

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
