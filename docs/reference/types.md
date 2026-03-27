# Data Types Reference

Complete specification of all core ztick data types.

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

- **execution** (i64): Unix timestamp in nanoseconds
  - `1711612800000000000` = 2024-03-28 12:00:00 UTC
  - Used for precise timing (nanosecond resolution)
  - Persisted as big-endian i64 in logfiles

- **status** (JobStatus): Current state (see below)

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
- **pattern**: Prefix pattern matching job identifiers
  - `supports()` returns the pattern length (as weight) if the job identifier starts with the pattern, `null` otherwise
  - Longer patterns take priority (more specific match wins)
  - Example: `SETRULE backup. SHELL /bin/backup.sh` matches `backup.daily`, `backup.weekly`, etc.

- **runner**: Execution target (see Runner below)

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
    amqp: struct {
        dsn: []const u8,
        exchange: []const u8,
        routing_key: []const u8,
    },
};
```

**Types**:

- **shell**: Execute a command in a POSIX shell
  - Supported
  - Example: `SHELL /usr/bin/backup.sh`

- **amqp**: Send a message to AMQP broker
  - Deferred (not yet implemented)
  - Fields: `dsn` (connection string), `exchange`, `routing_key`

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
  └─ if shell:
     [2 bytes: command length]
     [N bytes: command string]
  └─ if amqp:
     [2 bytes: dsn length]
     [N bytes: dsn string]
     [2 bytes: exchange length]
     [N bytes: exchange string]
     [2 bytes: routing_key length]
     [N bytes: routing_key string]
```

See [Persistence Format](persistence.md) for complete details.

## See Also

- **[Persistence Format](persistence.md)** — Binary encoding details
- **[Protocol Reference](protocol.md)** — How types map to protocol commands
- **[Architecture](../development/architecture.md)** — Domain layer design
