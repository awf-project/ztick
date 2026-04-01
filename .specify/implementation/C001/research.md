# Research: C001

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig (target), Rust (reference) |
| Domain | data (time-based job scheduler) |
| Task Type | chore (full rewrite) |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: The project constitution (`.specify/memory/constitution.md` v1.0.0) establishes strict governing principles for the Zig implementation:
1. **Hexagonal Architecture** with 4 layers: domain (`src/domain/`), application (`src/application/`), infrastructure (`src/infrastructure/`), interfaces (`src/interfaces/`). Domain MUST NOT depend on outer layers.
2. **TDD Methodology**: RED-GREEN-REFACTOR. Minimum 80% line coverage, 95%+ for domain module. Every public function needs at least one test.
3. **Zig Idioms**: Explicit over implicit, errors as values (error unions), no `catch unreachable` or `@panic` in library code, prefer `comptime`, use `std.log`, enforce `zig fmt`.
4. **Minimal Abstraction**: No interface without 2+ implementations, prefer composition, use tagged unions for domain concepts.

No ADRs exist yet (docs/ADR/ is empty). No prior claude-mem sessions found. The branch `issue/0-rewrite-kairoi-project-from-rust-to-zig` has no commits yet.

**Sources**: `.specify/memory/constitution.md`, `docs/ADR/README.md`, git status
**Recommendation**: Follow constitution strictly. Establish ADRs for major design decisions (concurrency model, dependency strategy, config format) early in the rewrite.

---

### Q1: [ARCH] What patterns should C001 follow?

**Finding**: The Rust Kairoi implementation uses a 3-component threaded architecture communicating via channels:
- **Controller** (`controller/`): TCP server on port 5678, handles client connections, parses KCP protocol messages, dispatches query requests. Runs at 128 Hz polling loop.
- **Database** (`database/`): Core scheduler with in-memory storage backed by persistent logfiles. Handles queries, triggers job execution, manages job state machine. Runs at configurable framerate (default 512 Hz).
- **Processor** (`processor/`): Execution dispatcher using select/epoll pattern. Routes execution requests to Shell or AMQP runners. Feature-gated (`runner-shell`, `runner-amqp`).

Message routing in `main.rs` connects components via crossbeam channels: Query channel (Controller <-> Database), Execution channel (Database <-> Processor).

**Hexagonal mapping for Zig port**:
- `src/domain/`: Job, Rule, Runner, JobStatus types; Instruction enum; protocol interfaces (Request/Response). ZERO external dependencies.
- `src/application/`: Database scheduler service, QueryHandler, ExecutionClient, rule-pairing logic, job state transitions.
- `src/infrastructure/`: Persistence layer (logfile reader/writer, encoder/decoder, background compression), Shell runner, AMQP runner, TCP networking.
- `src/interfaces/`: main.zig entry point, CLI argument parsing, TOML configuration loading.

**Sources**: `kairoi/src/main.rs:62-102`, `kairoi/src/controller/mod.rs`, `kairoi/src/database/mod.rs`, `kairoi/src/processor/mod.rs`, `.specify/memory/constitution.md`
**Recommendation**: Organize Zig code strictly per constitution hexagonal layers. Port domain types first (zero dependencies), then application logic, then infrastructure adapters, then interfaces. Replace Rust `crossbeam_channel` with Zig `std.Thread` + custom channel or event-driven approach.

---

### Q2: [TYPES] Which types can C001 reuse?

**Finding**: 47 types cataloged across 8 categories from the Rust reference implementation. Since this is a greenfield Zig project, none are "reusable" directly, but all must be ported. Key types organized by hexagonal layer:

**Domain layer types (port first)**:
- `JobStatus` enum: `Planned | Triggered | Executed | Failed` (`database/storage/job.rs:15-20`)
- `Job` struct: `{identifier: String, execution: DateTime<Utc>, status: JobStatus}` (`database/storage/job.rs:24-28`)
- `Rule` struct: `{identifier: String, pattern: String, runner: Runner}` (`database/storage/rule.rs:5-9`)
- `Runner` tagged union: `Shell{command} | Amqp{dsn, exchange, routing_key}` (`database/storage/rule.rs:46-56`) - NOTE: currently duplicated in 5 places in Rust, consolidate to single definition
- `Instruction` enum: `Set{identifier, execution} | RuleSet{identifier, pattern, runner}` (`query/instruction.rs:6-16`)
- Query `Request`/`Response` structs (`query/mod.rs:8-44`)
- Execution `Request`/`Response` with UUID tracking (`database/execution/protocol.rs`)

**Application layer types**:
- `Database` struct with `Storage`, `ExecutionClient`, `QueryHandler` (`database/mod.rs:30-36`)
- `JobStorage` with dual indexing: HashMap + sorted Vec for execution ordering (`database/storage/job.rs:61-64`)
- `ExecutionClient` with UUID-tracked triggered jobs (`database/execution/mod.rs:25-28`)

**Infrastructure layer types**:
- Persistence `Encoder`/`Decoder` for binary serialization (`database/storage/persistence/encoder.rs`)
- Logfile `Reader`/`Writer` with 4-byte length-prefixed entries (`database/storage/persistence/logfile/`)
- Background `Process` for logfile compression (`database/storage/persistence/background.rs`)
- `Clock` for framerate-limited execution (`database/framerate.rs:21-23`)

**Configuration types**:
- `Configuration{log: Log, controller: Controller, database: Database}` (`configuration.rs:78-88`)
- `LogLevel` enum: `Off | Error | Warn | Info | Debug | Trace`

**Rust-to-Zig type mapping**:
| Rust | Zig |
|------|-----|
| `Result<T, E>` | `E!T` (error union) |
| `Option<T>` | `?T` (optional) |
| `enum` variants | `union(enum)` (tagged union) |
| `trait` | comptime interface / vtable |
| `String` | `[]const u8` / allocated slice |
| `DateTime<Utc>` | `i64` (unix nanoseconds) or `i128` |
| `HashMap` | `std.StringHashMap` or `std.AutoHashMap` |
| `Vec<T>` | `std.ArrayList(T)` |
| `Uuid` | `[16]u8` or `u128` |
| `mpsc::channel` | custom channel or `std.Thread` primitives |

**Sources**: All `kairoi/src/**/*.rs` files analyzed
**Recommendation**: Define a single canonical `Runner` type in `src/domain/runner.zig` to eliminate the 5-way duplication. Port domain types first as they have zero dependencies. Use `i64` nanosecond timestamps instead of chrono DateTime. Use Zig's `std.crypto.random` for UUID generation.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: The Rust codebase contains 4 test modules with 9 test functions:
1. `database/storage/job.rs`: 3 tests - `single_set_get`, `get_to_execute`, `get_to_execute_with_sequential_modifications` (job storage operations, status filtering, ordered insertion)
2. `controller/client/parser.rs`: 1 test - `test_parse` with 13 assert_eq cases (valid/invalid/incomplete KCP protocol buffers, escaped strings)
3. `database/storage/persistence/encoder.rs`: 2 tests - `test_encode`, `test_decode` (binary serialization round-trip for Job/Rule/Runner variants)
4. `database/storage/persistence/logfile/encoding.rs`: 2 tests - `test_encode`, `test_parse` (length-prefixed logfile entry encoding, boundary cases, max size errors)

**Test patterns observed**:
- Co-located tests in `#[cfg(test)] mod tests` blocks (maps to Zig's inline `test` blocks)
- `assert_eq!` for value comparison (maps to `std.testing.expectEqual`)
- Deterministic fixtures with fixed timestamps (`Utc.ymd(2020, 7, 24).and_hms(10, 32, 00)`)
- Error case coverage: 30-40% of test cases cover error paths (incomplete, invalid, boundary)
- No integration tests exist in the Rust codebase

**Constitution requirements**:
- TDD: RED -> GREEN -> REFACTOR
- 80% minimum line coverage overall
- 95%+ coverage for domain module
- Every public function must have at least one test
- Unit tests co-located with source files
- Integration tests in `tests/` directory via `build.zig` test steps

**CI pipeline** (`.github/workflows/ci.yaml`): `zig fmt --check .` -> `zig build test` -> `zig build -Doptimize=ReleaseSafe`

**Sources**: `kairoi/src/database/storage/job.rs:136-204`, `kairoi/src/controller/client/parser.rs:62-121`, `kairoi/src/database/storage/persistence/encoder.rs:264-327`, `kairoi/src/database/storage/persistence/logfile/encoding.rs:92-155`, `.specify/memory/constitution.md`, `.github/workflows/ci.yaml`
**Recommendation**: Port all 9 existing Rust tests to Zig as baseline. Use `std.testing.allocator` for leak detection. Add integration tests for multi-component flows (Controller->Database->Processor). Use `std.testing.expectEqual` and `std.testing.expectError` for assertions. Target 95%+ coverage in domain module from day one.

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**:
1. **Branch state**: `issue/0-rewrite-kairoi-project-from-rust-to-zig` is a fresh branch with no commits. Kairoi is a git submodule from `github.com/emerick42/kairoi`.
2. **Kairoi evolution** (from CHANGELOG.md): Recent work focused on configurability - runtime config path via `-c/--config` CLI arg (PR #30), compile-time config path (PR #28). Current version 0.1.0, Rust edition 2018, rust-version 1.57.0.
3. **@TODO comments** (4 instances marking known technical debt):
   - `main.rs:85,96`: "Handle the channel disconnection properly" (currently panics)
   - `controller/mod.rs:36`: "Handle the connection" (incomplete)
   - `database/storage/persistence/mod.rs:324`: "Read compressed entries with iterations, instead of loading everything in memory" (performance concern)
4. **No ADRs exist** - the ADR directory has a template but no decisions recorded yet.
5. **Platform constraint**: README states "Kairoi currently targets running on Linux operating systems."
6. **Spec recommendation**: "Incremental porting (module by module) is recommended to allow continuous validation against the Rust version."

**Sources**: `kairoi/CHANGELOG.md`, `kairoi/README.md`, `docs/ADR/README.md`, Grep for `@TODO` in `kairoi/src/`, `.specify/implementation/C001/spec-content.md`
**Recommendation**: Address all 4 @TODOs properly in the Zig rewrite rather than deferring them. Establish ADRs for: (1) concurrency model, (2) dependency/config strategy, (3) persistence format compatibility. Follow incremental porting path: domain -> persistence -> application -> infrastructure -> interfaces.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: Since this is a full rewrite (not a migration), the Rust codebase serves only as reference. Key anti-patterns to NOT carry forward:

1. **23 `panic!()` calls** across the codebase - used as error handling strategy for channel disconnections, thread spawn failures, socket errors. Replace with proper error propagation via Zig error unions.
   - `main.rs:86,97`, `database/mod.rs:70`, `processor/mod.rs:89,103,107,121,125,146`, `controller/mod.rs:45,75`, `controller/client/mod.rs:44,52,58,97,112,116`, `database/query/mod.rs:38,46`, `database/execution/mod.rs:51,66`

2. **20+ `unwrap()` calls** - improper error handling on logger init, thread spawns, channel sends, socket operations. All should use Zig's `try` keyword.
   - `logger.rs:28-32`, `controller/mod.rs:24-27`, `processor/shell.rs:61,68`, `processor/amqp.rs:80,93`, `database/storage/persistence/background.rs:35`

3. **Runner enum duplicated 5 times** with slight variations (field ordering, derive attributes):
   - `execution/runner.rs`, `database/storage/rule.rs:46-56`, `database/execution/protocol.rs:20-30`, `processor/protocol.rs:20-30`, `database/storage/persistence/encoder.rs:27-36`
   - Consolidate to single canonical type in domain layer.

4. **1 unsafe code block** (`controller/client/mod.rs:137-139`): `std::str::from_utf8_unchecked` for UTF-8 lossy decoding. Implement safely in Zig.

5. **"Hard to maintain" message routing** (`main.rs:75-77` comment): Monolithic select! block for message routing. Design extensible routing in Zig.

6. **Deprecated Rust idioms**: `extern crate` declarations (`main.rs:1-10`) - Rust 2015 edition artifacts, not applicable to Zig.

**Sources**: Grep analysis of `panic!`, `unwrap()`, `unsafe`, `@TODO` across `kairoi/src/`
**Recommendation**: The Zig rewrite should:
- Use error unions consistently (no panics in library code per constitution)
- Define Runner once in `src/domain/runner.zig`
- Implement safe UTF-8 handling without unsafe blocks
- Design extensible message routing (comptime dispatch or trait-like pattern)
- Address all 4 @TODOs as first-class features rather than deferring

## Best Practices

| Pattern | Application in C001 |
|---------|----------------------------|
| Hexagonal Architecture | 4-layer structure: domain/application/infrastructure/interfaces with strict dependency rules |
| Tagged Unions | Use `union(enum)` for Runner, Instruction, JobStatus, Entry types |
| Error Unions | Replace all Rust `Result<T,E>` with Zig `E!T`; replace `Option<T>` with `?T` |
| Comptime Interfaces | Replace Rust traits (Chainable) with comptime function signatures |
| Explicit Allocators | Pass allocators explicitly to all types that need heap allocation |
| Co-located Tests | Place `test` blocks in each `.zig` source file per constitution |
| TDD (RED-GREEN-REFACTOR) | Write failing test first, implement minimum code to pass, then refactor |
| Build Options | Use `build.zig` options for feature flags (runner-shell, runner-amqp) instead of Cargo features |
| std.log | Use Zig's `std.log` for structured, scoped logging instead of external crate |
| Binary Protocol | Preserve Kairoi's custom binary persistence format (length-prefixed entries, big-endian encoding) |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| zig (compiler) | 0.14.1 | Build toolchain | required | `mlugg/setup-zig@v2` in CI |
| std.net | (stdlib) | TCP server for Controller | installed | none |
| std.Thread | (stdlib) | Concurrency for 3-component architecture | installed | none |
| std.fs | (stdlib) | Logfile persistence I/O | installed | none |
| std.process | (stdlib) | Shell runner subprocess execution | installed | none |
| std.crypto.random | (stdlib) | UUID generation (replace uuid crate) | installed | none |
| std.log | (stdlib) | Structured logging (replace log + simple_logger) | installed | none |
| std.json or custom TOML | (stdlib/custom) | Configuration parsing (replace config + serde) | missing | ADR needed: hand-write TOML parser, use simpler format, or vendor C lib |
| AMQP client | ^0.1.0 | AMQP runner (replace amiquip) | missing | ADR needed: vendor C library via @cImport, write minimal client, or defer feature |

## References

| File | Relevance |
|------|-----------|
| `kairoi/src/main.rs` | Entry point, component orchestration, message routing pattern |
| `kairoi/src/database/mod.rs` | Core scheduler: job triggering, result handling, storage initialization |
| `kairoi/src/database/storage/job.rs` | Job domain model + in-memory storage with tests (reference implementation) |
| `kairoi/src/database/storage/rule.rs` | Rule domain model with pattern matching logic |
| `kairoi/src/database/storage/persistence/mod.rs` | Append-only logfile persistence with background compression |
| `kairoi/src/database/storage/persistence/encoder.rs` | Binary encoding/decoding for Job/Rule with tests |
| `kairoi/src/database/storage/persistence/logfile/encoding.rs` | Length-prefixed logfile format with tests |
| `kairoi/src/controller/client/parser.rs` | KCP protocol parser (nom-based) with tests |
| `kairoi/src/controller/client/mod.rs` | TCP client handling, request building, response dispatch |
| `kairoi/src/processor/mod.rs` | Execution dispatcher with select/epoll pattern |
| `kairoi/src/processor/shell.rs` | Shell runner: subprocess execution via `sh` command |
| `kairoi/src/processor/amqp.rs` | AMQP runner: connection pooling, message publishing |
| `kairoi/src/configuration.rs` | TOML config loading with validation and defaults |
| `kairoi/docs/client-protocol.md` | KCP protocol specification (request-response, string encoding) |
| `kairoi/docs/instructions.md` | SET and RULE SET instruction documentation |
| `kairoi/docs/runners.md` | Shell and AMQP runner documentation |
| `kairoi/docs/configuration.md` | Configuration options documentation |
| `.specify/memory/constitution.md` | Project constitution: hexagonal arch, TDD, Zig idioms, minimal abstraction |
| `.github/workflows/ci.yaml` | CI pipeline: zig fmt, zig build test, zig build -Doptimize=ReleaseSafe |
