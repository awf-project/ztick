# Getting Started with ztick

This tutorial walks you through building, configuring, and running ztick for the first time.

## Prerequisites

- **Zig 0.15.2** or later ([download](https://ziglang.org/download/))
- A POSIX shell (bash, zsh, etc.)
- `socat` for sending TCP commands
- Basic familiarity with command-line tools
- **Optional**: `libssl-dev` (Debian/Ubuntu) or `openssl-devel` (Fedora/RHEL) if you want to build with TLS support

## Step 1: Build the Project

Clone or navigate to your ztick repository, then build:

```bash
make build
```

Run the tests to verify everything works:

```bash
make test
```

You should see output like:
```
Build Summary: 11/11 steps succeeded; 103/103 tests passed
```

## Step 2: Create a Configuration File

Create `config.toml` in your working directory:

```toml
[log]
level = "info"

[controller]
listen = "127.0.0.1:5678"

[database]
fsync_on_persist = false
framerate = 512
logfile_path = "ztick.log"
```

**What each section does:**
- `[log]` — Controls verbosity (off, error, warn, info, debug, trace)
- `[controller]` — TCP server address for client commands
- `[database]` — Persistence and timing settings

See [Configuration Reference](../reference/configuration.md) for all options.

## Step 3: Start the Scheduler

Run ztick with your configuration:

```bash
zig build run -- -c config.toml
```

You should see log output on stderr:

```
[INFO] config: config.toml
[INFO] log level: info
[INFO] listening on 127.0.0.1:5678
[INFO] loaded 0 jobs, 0 rules
```

The process is now listening for TCP connections on the configured address.

## Step 4: Create a Rule

Before creating jobs, define a rule that tells ztick what to do when a job triggers. Open a new terminal:

```bash
echo 'r1 RULE SET rule.example example. shell "/bin/echo Job_executed"' | socat - TCP:localhost:5678
```

You should receive:
```
r1 OK
```

This creates a rule that matches any job starting with `example.` and runs the echo command.

## Step 5: Create Your First Job

Schedule a job using a datetime timestamp:

```bash
echo 'r2 SET example.job.1 2026-03-28 22:00:00' | socat - TCP:localhost:5678
```

Response:
```
r2 OK
```

This schedules a job with:
- **Identifier**: `example.job.1`
- **Execution time**: `2026-03-28 22:00:00` UTC

You can also use nanosecond timestamps:

```bash
echo 'r3 SET example.job.2 1711612800000000000' | socat - TCP:localhost:5678
```

## Step 6: Check Job State

Use the `GET` command to verify a job was created and see its current state:

```bash
echo 'r4 GET example.job.1' | socat - TCP:localhost:5678
```

Response:
```
r4 OK planned 1743199200000000000
```

The response shows the job's status (`planned`) and its execution timestamp in nanoseconds.

Try querying a job that doesn't exist:

```bash
echo 'r5 GET no.such.job' | socat - TCP:localhost:5678
```

Response:
```
r5 ERROR
```

## Step 7: Verify Persistence

Stop ztick (Ctrl+C) and check the logfile:

```bash
ls -la ztick.log
```

The logfile contains binary-encoded entries of your jobs and rules.

Restart ztick:

```bash
zig build run -- -c config.toml
```

The log output now shows your persisted data was restored:

```
[INFO] config: config.toml
[INFO] log level: info
[INFO] listening on 127.0.0.1:5678
[INFO] loaded 2 jobs, 1 rules
```

Your jobs and rules are restored from the logfile. Send the same commands again to verify they still work.

## Step 8: Batch Commands

Send multiple commands at once:

```bash
{
  echo 'r1 RULE SET rule.batch batch. shell "/bin/echo batch-done"'
  echo 'r2 SET batch.job.1 2026-04-01 08:00:00'
  echo 'r3 SET batch.job.2 2026-04-01 09:00:00'
} | socat - TCP:localhost:5678
```

Each command returns its own response:
```
r1 OK
r2 OK
r3 OK
```

## Protocol Overview

Every command follows this format:

```
<request_id> <instruction> <args...>
```

| Command | Description | Example |
|---------|-------------|---------|
| `SET` | Create/update a job | `r1 SET job.name 2026-04-01 12:00:00` |
| `GET` | Retrieve job state | `r1 GET job.name` |
| `QUERY` | List jobs by prefix (or all) | `r1 QUERY job.` |
| `RULE SET` | Create/update a rule | `r1 RULE SET rule.name job. shell "/bin/cmd --flag"` |

See [Protocol Reference](../reference/protocol.md) for full details.

## Next Steps

- **[Writing Rules](../user-guide/writing-rules.md)** — Learn pattern matching and runners
- **[Configuration](../user-guide/configuration.md)** — Explore all options, including TLS setup
- **[Protocol Reference](../reference/protocol.md)** — Full protocol reference
- **[Architecture](../development/architecture.md)** — Understand the design

**Want to secure your deployment?** See the [TLS Setup Guide](../user-guide/configuration.md#setting-up-tls) for encrypting protocol traffic.

**Want to publish to a broker?** ztick can publish to AMQP 0-9-1 brokers (e.g. RabbitMQ) when a rule fires. A `compose.yaml` at the repo root boots a local RabbitMQ broker with the management UI on `http://localhost:15672`:

```bash
docker compose up -d
```

Then declare a rule whose runner is `amqp` and point it at the broker. See [Writing Rules → AMQP Runner](../user-guide/writing-rules.md#amqp-runner) for the full walkthrough including topology setup, message verification, and troubleshooting.

## Troubleshooting

### "Address already in use"
The port 5678 is occupied. Change `controller.listen` in config.toml to a different address.

### No response from commands
Verify ztick is running: `ss -tlnp | grep 5678`

### Process exits immediately
Check your config.toml syntax. Run without config to use defaults: `zig build run`
