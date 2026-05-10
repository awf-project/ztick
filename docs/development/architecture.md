---
title: "Hexagonal Architecture"
---

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
- `Runner` — Tagged union of `shell`, `direct`, `http`, `awf`, `amqp`, `redis`
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
- `JobStorage` — In-memory HashMap + priority queue for efficient job insertion (O(log n))
- `RuleStorage` — Rule persistence and pattern matching
- `QueryHandler` — Instruction → response conversion
- `ExecutionClient` — Tracks pending job executions

**Key property**: Depends only on Domain. No I/O or side effects.

**Performance note**: `JobStorage` uses `std.PriorityQueue` ordered by execution time for sub-linear insertion and sorted retrieval ([F021](../../.specify/implementation/F021/)). This ensures scheduling throughput scales to thousands of jobs without linear scan overhead.

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
- `TcpServer` — Listens for TCP protocol connections (thread per connection)
- `HttpServer` — RESTful JSON API server (thread per connection, mirrors TCP pattern)
- `ShellRunner` — Executes shell commands via `std.process`
- `Encoder`/`Logfile` — Binary persistence (read/write jobs and rules)
- `Parser` — Line protocol parsing
- `Telemetry` — OpenTelemetry SDK initialization and OTLP export ([ADR-0004](../ADR/0004-opentelemetry-sdk-dependency.md))
- `Channel` — Thread-safe bounded FIFO with `drain()` for single-lock batch consumption and optional wake notification ([F021](../../.specify/implementation/F021/))
- `Clock` — Event-driven tick scheduling with condition-variable wakeup and framerate enforcement ([F021](../../.specify/implementation/F021/))

**Key property**: Depends on Domain and Application. Handles all I/O.

**Performance note**: The database thread uses `Channel.drain()` to consume incoming requests in a single lock/unlock cycle, reducing contention at high concurrency. Event-driven `Clock` wakes immediately on incoming requests rather than sleeping for fixed intervals, reducing single-worker latency to sub-millisecond. Both TCP and HTTP servers spawn a detached thread per connection with atomic counter tracking, enabling concurrent request handling without blocking.

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

**Concurrency Pattern** ([F022](../../.specify/implementation/F022/)): Both TcpServer and HttpServer use an identical detached-thread pattern for handling concurrent connections:

1. **Accept loop** increments an atomic counter and spawns a detached thread per accepted connection
2. **Worker thread** processes the request and decrements the counter on exit (via `defer`)
3. **Graceful shutdown** via `join_all()` polls the counter until it reaches zero or 5-second timeout elapses

This lock-free pattern enables linear throughput scaling: each client gets its own thread without mutex contention, and the atomic counter enables safe shutdown coordination across threads.

Key benefits:
- **No head-of-line blocking** — slow clients don't block fast clients
- **Simple reasoning** — one thread per connection makes debugging straightforward
- **Proven pattern** — TCP server established this pattern; HTTP replicates it exactly
- **Graceful shutdown** — `join_all()` ensures all in-flight requests drain before exit

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

## Performance Optimizations

### Database Thread Throughput ([F021](../../.specify/implementation/F021/))

The database thread processes incoming job requests and triggers scheduled jobs. Three optimizations ensure it remains the throughput leader at scale:

**1. Priority Queue Storage (O(log n) insertion)**
- `JobStorage.to_execute` uses `std.PriorityQueue` ordered by execution time instead of sorted array
- Insertion: O(log n) vs O(n) linear scans + array shifts
- Supports thousands of scheduled jobs without throughput degradation

**2. Batch Request Drain (single lock/unlock)**
- `Channel.drain()` copies all buffered requests in one critical section
- Reduces lock contention from 500+ per second (individual try_receive) to ~1 per tick
- Multi-worker throughput scales closer to linearly

**3. Event-Driven Tick Scheduling (sub-millisecond latency)**
- `Clock` uses condition variable `timedWait()` instead of unconditional `Thread.sleep()`
- Wakes immediately when requests arrive; sleeps only when idle
- Single-worker p50 latency drops from 2.24ms to <1ms
- Framerate acts as a tick cap to prevent busy-spinning under sustained load

**Benchmark targets** (8 TCP workers):
- Throughput: >3000 msg/s (6x improvement)
- p50 latency: <5ms (68% reduction)
- p99 latency: <15ms (53% reduction)

See [Building the Project](building.md#performance-profiling) for benchmark instructions.

### HTTP Server Concurrency ([F022](../../.specify/implementation/F022/))

The HTTP server spawns a dedicated thread per accepted connection, mirroring the TCP server's detached-thread pattern:

- **Thread per connection** — Each HTTP request is handled in its own thread, eliminating head-of-line blocking in the accept loop
- **Atomic counter tracking** — An `active_connections` atomic counter tracks live worker threads for graceful shutdown
- **Graceful shutdown** — `join_all()` polls the counter with a 5-second timeout, ensuring in-flight requests complete before process exit
- **Shared state safety** — `ResponseRouter` and `Channel` are mutex-guarded; `next_client_id` uses atomic `fetchAdd`

**Benchmark targets** (8 HTTP workers):
- Throughput: >2000 msg/s (4x improvement over sequential baseline)
- p50 latency: <5ms (vs ~56ms under 16 concurrent workers previously)

## Key Principles

1. **Domain is pure** — no I/O, no dependencies
2. **Application is testable** — depends only on domain
3. **Infrastructure is flexible** — adapters are swappable
4. **Interfaces are thin** — just wiring and config
5. **Tests are co-located** — each file includes its own tests

## See Also

- **[Building](building.md)** — How to compile and test the project
- **[Contributing](contributing.md)** — Code style and submission guidelines
