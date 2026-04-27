# Hexagonal Architecture

ztick uses **hexagonal architecture** (also called "ports and adapters") to maintain a clean separation of concerns and testability.

## Layer Structure

The codebase is organized into 4 layers, with a strict dependency direction (inward only):

```
┌─────────────────────────────────────────────────────┐
│ Interfaces (CLI, Config)                            │
├─────────────────────────────────────────────────────┤
│ Infrastructure (Adapters: TCP, Shell, Persistence,  │
│                 Telemetry)                          │
├─────────────────────────────────────────────────────┤
│ Application (Scheduler, Storage, Query Handler)     │
├─────────────────────────────────────────────────────┤
│ Domain (Job, Rule, Runner, Execution)               │
└─────────────────────────────────────────────────────┘
     ↑ Dependencies flow inward only
```

### Layer 1: Domain (`src/domain/`)

**Purpose**: Pure data types and business logic with zero external dependencies.

**Exports**:
- `Job` — Scheduled action with status
- `JobStatus` — `planned`, `triggered`, `executed`, `failed`
- `Rule` — Pattern-based job-to-runner mapping
- `Runner` — Tagged union of `shell`, `direct`, `http`, `awf`, `amqp`
- `Instruction` — `set`, `remove`, `query` operations
- `Request`/`Response` — Query protocol

**Key property**: No imports from outer layers. Tests can run standalone.

**Example**: Define a job type with lifecycle methods
```zig
pub const Job = struct {
    identifier: []const u8,
    execution: i64,  // nanosecond timestamp
    status: JobStatus,
};
```

### Layer 2: Application (`src/application/`)

**Purpose**: Core scheduler logic—storage, pattern matching, query handling.

**Exports**:
- `Scheduler` — Main orchestrator
- `JobStorage` — In-memory HashMap + sorted execution queue
- `RuleStorage` — Rule persistence and pattern matching
- `QueryHandler` — Instruction → response conversion
- `ExecutionClient` — Tracks pending job executions

**Key property**: Depends only on Domain. No I/O or side effects.

**Example**: Scheduler tick loop
```zig
pub fn tick(self: *Scheduler, now: i64) !void {
    const to_execute = try self.job_storage.get_to_execute(now);
    for (to_execute) |job| {
        const rule = self.rule_storage.find_rule_for(job.identifier);
        try self.execution_client.trigger(job, rule);
    }
}
```

### Layer 3: Infrastructure (`src/infrastructure/`)

**Purpose**: Adapters that connect the application to external systems.

**Exports**:
- `TcpServer` — Listens for TCP protocol connections
- `ShellRunner` — Executes shell commands via `std.process`
- `Encoder`/`Logfile` — Binary persistence (read/write jobs and rules)
- `Parser` — Line protocol parsing
- `Telemetry` — OpenTelemetry SDK initialization and OTLP export ([ADR-0004](../ADR/0004-opentelemetry-sdk-dependency.md))
- `Channel` — Thread-safe bounded message passing
- `Clock` — Framerate timing

**Key property**: Depends on Domain and Application. Handles all I/O.

**Example**: TCP adapter accepts connections and routes commands
```zig
pub const TcpServer = struct {
    pub fn handle_connection(
        self: *TcpServer,
        scheduler: *application.Scheduler,
        socket: std.net.Stream,
    ) !void {
        var parser = Parser.init(socket);
        while (try parser.next_instruction()) |instr| {
            const response = try scheduler.handle_query(instr);
            try socket.write(response);
        }
    }
};
```

### Layer 4: Interfaces (`src/interfaces/`)

**Purpose**: Entry point—command-line parsing, configuration loading, component wiring.

**Exports**:
- `main()` — Parses args, loads config, spawns threads
- `Config` — TOML configuration
- `Cli` — Argument parsing

**Key property**: Depends on all layers. Orchestrates the entire system.

**Example**: Main function wires up all components
```zig
pub fn main() !void {
    var config = try load_config(args.config_path);
    var scheduler = try application.Scheduler.init(allocator);
    var tcp_server = try infrastructure.TcpServer.bind(config.controller.listen);

    try tcp_server.listen(scheduler);
}
```

## Dependency Inversion

The hexagonal pattern uses **dependency inversion** to keep dependencies flowing inward:

### Without Hexagonal (Tightly Coupled)
```
main.zig
  ├─ TcpServer
  │  ├─ Scheduler
  │  │  ├─ Job
  │  │  └─ Rule
  │  └─ Encoder (I/O)
  └─ Encoder (I/O)

Problem: Application depends on I/O; hard to test
```

### With Hexagonal (Inverted)
```
main.zig (orchestrates)
  ├─ TcpServer (adapter) → calls
  │  └─ Scheduler (application) → uses
  │     └─ Job, Rule (domain)

TcpServer is separate; Scheduler is testable without I/O
```

## Testing Strategy

Each layer is tested independently:

### Domain Tests
- Pure data structures
- Status transitions
- Pattern matching logic
- **No I/O or allocation tracking needed**

Example: `src/domain/job.zig` includes inline tests

```zig
test "job lifecycle" {
    var job = Job{ .identifier = "test", .status = .planned };
    job.status = .triggered;
    try std.testing.expectEqual(JobStatus.triggered, job.status);
}
```

### Application Tests
- Scheduler behavior
- Storage operations
- Rule resolution
- **No actual TCP or file I/O**

Example: `src/application/scheduler.zig` tests

```zig
test "scheduler triggers matching jobs" {
    var scheduler = try Scheduler.init(allocator);
    try scheduler.handle_query(Request{ .instruction = .{ .set = ... } });
    try scheduler.tick(1000);
    try std.testing.expect(job.status == .triggered);
}
```

### Infrastructure Tests
- Parsing (protocol, TOML)
- Encoding/decoding (persistence)
- Channel correctness
- **Mock I/O where possible; real I/O in integration tests**

Example: `src/infrastructure/protocol/parser.zig` tests

```zig
test "parse protocol line" {
    var parser = Parser.init("SET job.1 1234567890");
    const instr = try parser.next_instruction();
    try std.testing.expectEqual(InstructionType.set, instr.type);
}
```

### Functional Tests
- End-to-end behavior
- Component interaction
- Full tick cycle

Example: `src/functional_tests.zig`

```zig
test "scheduler processes job from query to executed" {
    var scheduler = try Scheduler.init(allocator);
    try scheduler.handle_query(Request{ .instruction = .{ .set = ... } });
    try scheduler.tick(1000);
    // Verify job is executed
}
```

## Adding a New Feature

1. **Define domain types** → `src/domain/new_concept.zig`
   - No external dependencies
   - Include unit tests

2. **Implement application logic** → `src/application/handler.zig`
   - Uses domain types
   - Tested without I/O

3. **Add infrastructure adapter** → `src/infrastructure/adapter.zig`
   - Implements the interface
   - Handles side effects

4. **Wire in interfaces** → `src/main.zig`
   - Compose the feature into the system
   - Update CLI/config as needed

5. **Add functional test** → `src/functional_tests.zig`
   - Verify end-to-end behavior

## Key Principles

1. **Domain is pure** — no I/O, no dependencies
2. **Application is testable** — depends only on domain
3. **Infrastructure is flexible** — adapters are swappable
4. **Interfaces are thin** — just wiring and config
5. **Tests are co-located** — each file includes its own tests

## See Also

- **[Building](building.md)** — How to compile and test the project
- **[Contributing](contributing.md)** — Code style and submission guidelines
