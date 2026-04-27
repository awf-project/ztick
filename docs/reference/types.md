# Data Types Reference

Complete specification of all core ztick data types.

> **HTTP API Users**: These Zig types correspond directly to the HTTP API schemas defined in [openapi.yaml](../../openapi.yaml) and documented in the [HTTP API Reference](http-api.md). The HTTP API uses the field names shown in the "HTTP Schema" sections below.

## Core Types

### Job

A scheduled action with an execution timestamp.

```zig
pub const Job = struct {
    identifier: []const u8,  // Unique job identifier
    execution: i64,          // Execution timestamp (nanoseconds since Unix epoch)
    status: JobStatus,       // Current state
};
```

**Fields**:

- **identifier** (string): Unique identifier for this job
  - Alphanumeric, dots allowed
  - Example: `app.job.123`, `backup.daily`, `report.monthly`
  - HTTP API field name: `id`

- **execution** (i64): Unix timestamp in nanoseconds
  - `1711612800000000000` = 2024-03-28 12:00:00 UTC
  - Used for precise timing (nanosecond resolution)
  - Persisted as big-endian i64 in logfiles
  - HTTP API field name: `execution` (response as nanoseconds, request as ISO 8601 string)

- **status** (JobStatus): Current state (see below)
  - HTTP API field name: `status`

**Lifecycle**:

```
┌─────────┐
│ planned │ (newly created, waiting for execution time)
└────┬────┘
     │
     ├─────────────────────────────────────────┐
     │                                         │
     ▼                                         ▼
┌───────────┐ (execution time reached,  ┌──────────┐
│ triggered │  waiting for runner)      │  failed  │
└─────┬─────┘                           └──────────┘
      │
      ▼
┌──────────┐
│ executed │ (runner completed successfully)
└──────────┘
```

### JobStatus

Enumeration of possible job states.

```zig
pub const JobStatus = enum {
    planned,      // Created but execution time not yet reached
    triggered,    // Execution time reached, runner in progress
    executed,     // Runner completed successfully
    failed,       // Runner failed or was aborted
};
```

| Status | Meaning | Next States |
|--------|---------|-------------|
| `planned` | Awaiting execution time | `triggered`, `failed` |
| `triggered` | Runner executing | `executed`, `failed` |
| `executed` | Success | (terminal) |
| `failed` | Error or abort | (terminal) |

### Rule

Pattern-based mapping of jobs to runners.

```zig
pub const Rule = struct {
    identifier: []const u8,  // Unique rule identifier (usually the pattern)
    pattern: []const u8,     // Prefix pattern to match job identifiers
    runner: Runner,          // What to execute (tagged union)

    pub fn supports(self: *const Rule, job: []const u8) ?usize;
};
```

**Fields**:

- **identifier**: Unique rule name (typically the pattern)
  - HTTP API field name: `id`
- **pattern**: Prefix pattern matching job identifiers
  - `supports()` returns the pattern length (as weight) if the job identifier starts with the pattern, `null` otherwise
  - Longer patterns take priority (more specific match wins)
  - Example: `SETRULE backup. SHELL /bin/backup.sh` matches `backup.daily`, `backup.weekly`, etc.
  - HTTP API field name: `pattern`

- **runner**: Execution target (see Runner below)
  - HTTP API field name: `runner` (as discriminated union)

**Pattern Matching Examples**:

| Pattern | Matches | Does not match |
|---------|---------|----------------|
| `backup.` | `backup.daily`, `backup.hourly` | `app.backup`, `backup` |
| `app.job.` | `app.job.1`, `app.job.2` | `app.job`, `job.app.1` |

### Runner

Tagged union of possible execution targets.

```zig
pub const Runner = union(enum) {
    shell: struct {
        command: []const u8,
    },
    direct: struct {
        executable: []const u8,
        args: []const []const u8,
    },
    http: struct {
        method: []const u8,
        url: []const u8,
    },
    awf: struct {
        workflow: []const u8,
        input: ?[]const u8,
    },
    amqp: struct {
        dsn: []const u8,
        exchange: []const u8,
        routing_key: []const u8,
    },
    redis: struct {
        url: []const u8,
        command: []const u8,
        key: []const u8,
    },
};
```

**Types**:

- **shell**: Execute a command in a POSIX shell
  - Supported via TCP protocol and HTTP API
  - HTTP schema: `{"type": "shell", "command": "..."}`
  - Example: `shell /usr/bin/backup.sh`

- **direct**: Execute a binary directly via execve without shell interpretation
  - Supported via TCP protocol and HTTP API
  - Fields: `executable` (path to binary), `args` (literal argv elements)
  - HTTP schema: `{"type": "direct", "executable": "...", "args": [...]}`
  - Example: `direct /usr/bin/curl -s http://example.com`

- **http**: Trigger an external webhook via HTTP/HTTPS request
  - Supported via TCP protocol and HTTP API
  - Fields: `method` (HTTP verb: GET, POST, PUT, DELETE), `url` (target URL)
  - TCP syntax: `http <METHOD> <URL>` (e.g., `http POST https://hooks.example.com/webhook`)
  - HTTP request: `{"pattern": "...", "runner": "http", "args": ["POST", "https://hooks.example.com/webhook"]}`
  - POST and PUT requests include JSON body: `{"job_id":"<identifier>","execution":<timestamp_ns>}`
  - GET and DELETE requests send no body
  - TLS support: `https://` URLs establish encrypted connections
  - Timeout: 30-second connection and read timeout to prevent blocking
  - Success: HTTP 2xx status codes; all others are treated as failure

- **awf**: Execute an AWF (AI Workflow) via the AWF CLI
  - Supported via TCP protocol and HTTP API
  - Fields: `workflow` (workflow name), `inputs` (array of key=value parameters)
  - HTTP request: `{"pattern": "...", "runner": "awf", "args": ["<workflow>", "--input", "key=value", ...]}`
  - Example: `awf code-review` or `awf generate-report --input format=pdf --input target=main`

- **amqp**: Publish a message to an AMQP 0-9-1 broker
  - Supported via TCP protocol only (not exposed in HTTP API)
  - Fields: `dsn` (connection string), `exchange`, `routing_key`
  - DSN format: `amqp://[user[:password]@]host[:port][/vhost]`
  - Message body is the job identifier (u128 hex string)
  - TCP syntax: `amqp <dsn> <exchange> <routing_key>` (e.g. `amqp amqp://guest:guest@localhost:5672/ jobs notifications`)
  - Plaintext AMQP only; TLS support (`amqps://`) deferred
  - Per-execution connect/handshake/publish/close (no pooling); 30-second socket timeout
  - See [user-guide/writing-rules.md#amqp-runner](../user-guide/writing-rules.md#amqp-runner) for end-to-end usage, broker setup, verification, and troubleshooting

- **redis**: Send a single Redis command (PUBLISH/RPUSH/LPUSH/SET) to a Redis server
  - Supported via TCP protocol only (not exposed in HTTP API)
  - Fields: `url` (connection string), `command` (one of `PUBLISH`, `RPUSH`, `LPUSH`, `SET` — case-sensitive), `key` (channel/list/key)
  - URL format: `redis://[user[:password]@]host[:port][/db]` (plaintext only — `rediss://` is rejected at parse time)
  - The job identifier is sent as the value/payload of the configured command
  - TCP syntax: `redis <url> <command> <key>` (e.g. `redis redis://127.0.0.1:6379/0 PUBLISH deploy:events`)
  - Per-execution connect → optional `AUTH` (single- or two-arg form) → optional `SELECT <db>` → command → close (no pooling); 30-second socket timeout
  - Credentials present in the URL are redacted from logs
  - See [ADR-0006](../ADR/0006-redis-runner-design.md) for the persistence discriminant rationale (byte `5`, the next available value after the existing 0–4 mapping)
  - See [user-guide/writing-rules.md#redis-runner](../user-guide/writing-rules.md#redis-runner) for end-to-end usage and worked examples

### Instruction

Commands received from clients via the TCP protocol.

```zig
pub const Instruction = union(enum) {
    set: struct {
        identifier: []const u8,
        execution: i64,
    },
    rule_set: struct {
        identifier: []const u8,
        pattern: []const u8,
        runner: Runner,
    },
};
```

**Types**:

| Type | Purpose | Example |
|------|---------|---------|
| `set` | Create/update job | `SET my.job 1711612800` |
| `rule_set` | Create/update rule | `SETRULE my.rule my. SHELL /bin/cmd` |

### Query Request

Query request from client.

```zig
pub const Client = u128;

pub const Request = struct {
    client: Client,              // Client ID (TCP connection)
    identifier: []const u8,      // Request identifier
    instruction: Instruction,    // What to do
};
```

### Query Response

Query response to client.

```zig
pub const Response = struct {
    request: Request,   // Original request
    success: bool,      // Whether the operation succeeded
};
```

### Execution Request

Sent from the scheduler to the processor thread when a job is triggered.

```zig
pub const Request = struct {
    identifier: u128,            // UUID for this execution attempt
    job_identifier: []const u8,  // Which job to execute
    runner: Runner,              // How to execute it
};
```

### Execution Response

Sent from the processor thread back to the scheduler with the result.

```zig
pub const Response = struct {
    identifier: u128,   // Matches the execution request UUID
    success: bool,      // Whether the runner succeeded
};
```

## Type Examples

### Creating a Job

```zig
const job = Job{
    .identifier = "backup.daily",
    .execution = 1711612800000000000,  // nanoseconds
    .status = .planned,
};
```

### Creating a Rule

```zig
const rule = Rule{
    .identifier = "backup.",
    .pattern = "backup.",
    .runner = .{ .shell = .{ .command = "/usr/bin/backup.sh" } },
};
```

### Creating an HTTP Rule

```zig
const http_rule = Rule{
    .identifier = "rule.notify",
    .pattern = "deploy.",
    .runner = .{ .http = .{ .method = "POST", .url = "https://hooks.example.com/webhook" } },
};

const http_get_rule = Rule{
    .identifier = "rule.ping",
    .pattern = "health.",
    .runner = .{ .http = .{ .method = "GET", .url = "https://api.internal/trigger" } },
};
```

### Creating an AMQP Rule

```zig
const amqp_rule = Rule{
    .identifier = "rule.notify",
    .pattern = "notify.",
    .runner = .{ .amqp = .{
        .dsn = "amqp://guest:guest@localhost:5672/",
        .exchange = "jobs",
        .routing_key = "notifications",
    } },
};
```

### Creating a Redis Rule

```zig
// PUBLISH to a channel
const redis_publish_rule = Rule{
    .identifier = "rule.publish",
    .pattern = "deploy.",
    .runner = .{ .redis = .{
        .url = "redis://127.0.0.1:6379/0",
        .command = "PUBLISH",
        .key = "deploy:events",
    } },
};

// RPUSH to a list (worker queue)
const redis_queue_rule = Rule{
    .identifier = "rule.queue",
    .pattern = "backup.",
    .runner = .{ .redis = .{
        .url = "redis://127.0.0.1:6379/0",
        .command = "RPUSH",
        .key = "backup:tasks",
    } },
};
```

### Creating an AWF Rule

```zig
// AWF rule without inputs
const awf_rule_simple = Rule{
    .identifier = "rule.review",
    .pattern = "code-review.",
    .runner = .{ .awf = .{ .workflow = "code-review", .inputs = &.{} } },
};

// AWF rule with inputs
const awf_rule_with_inputs = Rule{
    .identifier = "rule.report",
    .pattern = "report.",
    .runner = .{ .awf = .{ .workflow = "generate-report", .inputs = &.{ "format=pdf", "target=main" } } },
};
```

### Creating an Instruction

```zig
const instr = Instruction{
    .set = .{
        .identifier = "job.1",
        .execution = 1711612800000000000,
    },
};
```

## Memory Ownership

All strings are borrowed references (`[]const u8`):

- Allocated by the caller
- Must remain valid for the lifetime of use
- Persisted structures dupe strings as needed

Example:

```zig
var job = try allocator.create(Job);
job.identifier = try allocator.dupe(u8, "my.job");  // Own the string
defer allocator.free(job.identifier);
```

## Encoding (Persistence)

Types are persisted in binary format:

### Job Encoding

```
[1 byte: type marker = 0]
[2 bytes: identifier length (big-endian u16)]
[N bytes: identifier string]
[8 bytes: execution timestamp (big-endian i64)]
[1 byte: status enum discriminant (0=planned, 1=triggered, 2=executed, 3=failed)]
```

### Rule Encoding

```
[1 byte: type marker = 1]
[2 bytes: identifier length (big-endian u16)]
[N bytes: identifier string]
[2 bytes: pattern length (big-endian u16)]
[N bytes: pattern string]
[1 byte: runner type discriminant]
  └─ if shell (0):
     [2 bytes: command length]
     [N bytes: command string]
  └─ if amqp (1):
     [2 bytes: dsn length]
     [N bytes: dsn string]
     [2 bytes: exchange length]
     [N bytes: exchange string]
     [2 bytes: routing_key length]
     [N bytes: routing_key string]
  └─ if direct (2):
     [2 bytes: executable length]
     [N bytes: executable string]
     [2 bytes: args count (big-endian u16)]
     for each arg:
       [2 bytes: arg length]
       [N bytes: arg string]
  └─ if awf (3):
     [2 bytes: workflow length]
     [N bytes: workflow string]
     [2 bytes: inputs count (big-endian u16)]
     for each input:
       [2 bytes: input length]
       [N bytes: input string (key=value)]
  └─ if http (4):
     [2 bytes: method length]
     [N bytes: method string (GET|POST|PUT|DELETE)]
     [2 bytes: url length]
     [N bytes: url string]
  └─ if redis (5):
     [2 bytes: url length]
     [N bytes: url string]
     [2 bytes: command length]
     [N bytes: command string (PUBLISH|RPUSH|LPUSH|SET)]
     [2 bytes: key length]
     [N bytes: key string]
```

> **Discriminant note**: Redis uses byte `5` (the next available value after `0=shell`, `1=amqp`, `2=direct`, `3=awf`, `4=http`). Existing logfiles already encode these five values, so the redis variant appended a new discriminant rather than renumbering. See [ADR-0006](../ADR/0006-redis-runner-design.md) for the rationale.

See [Persistence Format](persistence.md) for complete details.

## See Also

- **[Persistence Format](persistence.md)** — Binary encoding details
- **[Protocol Reference](protocol.md)** — How types map to protocol commands
- **[Architecture](../development/architecture.md)** — Domain layer design
