# Implementation Plan: C001

## Summary

Rewrite the Kairoi time-based job scheduler from Rust to Zig, following strict hexagonal architecture with 4 layers (domain, application, infrastructure, interfaces). The port proceeds inside-out: domain types first (zero dependencies), then application logic, infrastructure adapters, and finally the CLI entry point, preserving the binary persistence format and KCP protocol for feature parity.

## Constitution Compliance

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal Architecture (4 layers) | COMPLIANT | domain -> application -> infrastructure -> interfaces, strict dependency direction |
| TDD (RED-GREEN-REFACTOR) | COMPLIANT | Each component includes co-located tests; 95%+ domain coverage target |
| Zig Idioms (error unions, comptime, std.log) | COMPLIANT | All Rust `Result`/`Option`/`panic!` replaced with error unions, optionals, `try` |
| Minimal Abstraction | COMPLIANT | Single canonical `Runner` tagged union; no interface without 2+ implementations |
| No `@panic` in library code | COMPLIANT | All 23 Rust `panic!()` calls replaced with proper error propagation |
| `zig fmt` enforced | COMPLIANT | CI pipeline runs `zig fmt --check .` |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.14.1 (target), Rust (reference at `kairoi/`) |
| Framework | None (stdlib only) |
| Architecture | Hexagonal (domain/application/infrastructure/interfaces) |
| Key patterns | Tagged unions, error unions, explicit allocators, comptime interfaces, co-located tests |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | Timestamp representation in Zig (Rust uses `chrono::DateTime<Utc>`) | Use `i64` nanosecond unix timestamps. The binary encoder already stores timestamps as `i64` big-endian nanoseconds. | `kairoi/src/database/storage/persistence/encoder.rs:86-88` — `Utc.timestamp(timestamp / 1_000_000_000, ...)` and `job.execution.timestamp_nanos().to_be_bytes()` at line 164 |
| A2 | TOML configuration parsing (Rust uses `config` + `serde` crates) | Hand-write a minimal TOML parser supporting only the flat key-value and section syntax used by Kairoi's config. The config structure is simple (3 sections, 4 values, all primitives). | `kairoi/src/configuration.rs:78-88` — only `log.level` (enum), `controller.listen` (string), `database.fsync_on_persist` (bool), `database.framerate` (int) |
| A3 | AMQP runner dependency (Rust uses `amiquip` crate) | Defer AMQP runner to a future component. Implement the `Runner` tagged union with the AMQP variant, but the infrastructure adapter returns an error. Shell runner is the priority. | `kairoi/src/processor/mod.rs:8-9` — AMQP is feature-gated (`#[cfg(feature = "runner-amqp")]`), indicating it's optional |
| A4 | Channel-based inter-thread communication (Rust uses `crossbeam_channel`) | Use Zig `std.Thread` with a custom bounded channel built on `std.Thread.Mutex` + `std.Thread.Condition`. The Rust implementation uses `unbounded()` channels between 3 threads. | `kairoi/src/main.rs:57-60` — 4 unbounded channels connecting Controller, Database, Processor |
| A5 | UUID generation for execution tracking (Rust uses `uuid` crate) | Use `std.crypto.random` to generate 128-bit UUIDs. The execution protocol only needs unique identifiers. | `kairoi/src/database/execution/mod.rs:25-28` — UUID used as execution request identifier |
| A6 | KCP protocol parser (Rust uses `nom` combinators) | Hand-write a streaming parser in Zig. The protocol is simple: newline-terminated lines with space-separated arguments, supporting quoted strings with backslash escaping. | `kairoi/src/controller/client/parser.rs:30-60` — the full parser is ~60 lines of nom combinators |

## Approach Comparison

| Criteria | Approach A: Inside-Out Layered | Approach B: Component-by-Component | Approach C: Monolithic Port |
|----------|-------------------------------|-----------------------------------|-----------------------------|
| Description | Port by hexagonal layer: all domain types, then all application services, then all infrastructure, then interfaces | Port by Rust component: Controller fully, then Database fully, then Processor fully | Port everything into a flat structure, refactor into layers afterward |
| Files touched | ~15 | ~15 | ~10 initially, ~15 after refactor |
| New abstractions | 0 (direct port to tagged unions) | 0 | 0 initially, many during refactor |
| Risk level | Low | Med | High |
| Reversibility | Easy (each layer is independently testable) | Easy (each component works standalone) | Hard (refactor requires rework) |

**Selected: Approach A (Inside-Out Layered)**
**Rationale:** The constitution mandates strict hexagonal architecture with dependency inversion. Building domain first ensures zero-dependency types are tested in isolation before application logic depends on them. This matches the constitution's "domain MUST NOT depend on outer layers" rule and enables 95%+ domain coverage early.
**Trade-off accepted:** Cannot validate end-to-end component behavior until later components are built (Approach B would give working subsystems sooner). Mitigated by comprehensive unit tests per layer.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| Single canonical `Runner` in `src/domain/runner.zig` | Rust codebase has 5 duplicate Runner definitions (`execution/runner.rs`, `database/storage/rule.rs:46-56`, `database/execution/protocol.rs:20-30`, `processor/protocol.rs:20-30`, `encoder.rs:27-36`). Constitution says "tagged unions for domain concepts". | Keeping separate Runner types per module (matches Rust, but violates DRY and constitution) |
| `i64` nanosecond timestamps instead of datetime library | Binary format already uses i64 nanoseconds (`encoder.rs:164`). No chrono equivalent needed. Zig stdlib has no datetime library; hand-rolling one adds complexity for zero benefit. | Import a Zig datetime library (unnecessary dependency, violates minimal abstraction) |
| Preserve binary persistence format exactly | Enables reading logfiles created by the Rust implementation during migration. Format is well-defined: 4-byte length prefix, type byte, big-endian sized strings. | Design a new format (breaks migration path, no benefit) |
| Hand-written TOML parser (minimal subset) | Only 3 sections with 4 primitive values needed. A full TOML parser is overkill. Constitution says "simple code over clever solutions". | Vendor a C TOML library via `@cImport` (heavy dependency for trivial config) |
| Defer AMQP runner implementation | AMQP is feature-gated in Rust, requires external C library binding. Shell runner covers the primary use case. AMQP variant exists in the tagged union for type completeness. | Implement AMQP immediately (blocks delivery on external dependency research) |
| Custom channel over lock-free queue | Zig stdlib provides `Mutex` and `Condition`. A simple bounded channel is straightforward to implement and matches the Rust `unbounded()` pattern. | Use `std.event` or async (Zig async is not stable in 0.14.1) |

## Components

```json
[
  {
    "name": "domain_types",
    "project": "",
    "layer": "domain",
    "description": "Core domain types: Job, JobStatus, Rule, Runner tagged unions, Instruction enum, Query Request/Response, Execution Request/Response. Single canonical definitions used by all layers.",
    "files": [
      "src/domain/job.zig",
      "src/domain/rule.zig",
      "src/domain/runner.zig",
      "src/domain/instruction.zig",
      "src/domain/query.zig",
      "src/domain/execution.zig",
      "src/domain.zig"
    ],
    "tests": [
      "src/domain/job.zig",
      "src/domain/rule.zig"
    ],
    "dependencies": [],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test --test-filter domain",
      "expected_output": "All 0 tests passed.",
      "build_command": "zig build"
    }
  },
  {
    "name": "persistence_codec",
    "project": "",
    "layer": "infrastructure",
    "description": "Binary encoder/decoder for Job and Rule entries (preserving Kairoi's format: type byte, big-endian u16 string lengths, i64 nanosecond timestamps, status byte). Logfile entry encoder/parser with 4-byte length-prefixed entries. Reader/Writer for logfile I/O.",
    "files": [
      "src/infrastructure/persistence/encoder.zig",
      "src/infrastructure/persistence/logfile.zig",
      "src/infrastructure/persistence.zig"
    ],
    "tests": [
      "src/infrastructure/persistence/encoder.zig",
      "src/infrastructure/persistence/logfile.zig"
    ],
    "dependencies": ["domain_types"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test --test-filter persistence",
      "expected_output": "All 0 tests passed.",
      "build_command": "zig build"
    }
  },
  {
    "name": "application_scheduler",
    "project": "",
    "layer": "application",
    "description": "Core scheduler logic: JobStorage (HashMap + sorted Vec for execution ordering), RuleStorage with pattern-based pairing, QueryHandler for processing instructions, ExecutionClient for tracking triggered jobs with UUID, Database service orchestrating the tick loop.",
    "files": [
      "src/application/job_storage.zig",
      "src/application/rule_storage.zig",
      "src/application/query_handler.zig",
      "src/application/execution_client.zig",
      "src/application/scheduler.zig",
      "src/application.zig"
    ],
    "tests": [
      "src/application/job_storage.zig",
      "src/application/rule_storage.zig",
      "src/application/query_handler.zig"
    ],
    "dependencies": ["domain_types"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test --test-filter application",
      "expected_output": "All 0 tests passed.",
      "build_command": "zig build"
    }
  },
  {
    "name": "protocol_parser",
    "project": "",
    "layer": "infrastructure",
    "description": "KCP protocol streaming parser: newline-terminated lines, space-separated arguments, simple and quoted string support with backslash escaping. Converts parsed tokens into domain Instruction types.",
    "files": [
      "src/infrastructure/protocol/parser.zig",
      "src/infrastructure/protocol.zig"
    ],
    "tests": [
      "src/infrastructure/protocol/parser.zig"
    ],
    "dependencies": ["domain_types"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test --test-filter protocol",
      "expected_output": "All 0 tests passed.",
      "build_command": "zig build"
    }
  },
  {
    "name": "infrastructure_adapters",
    "project": "",
    "layer": "infrastructure",
    "description": "TCP server (Controller adapter), Shell runner (subprocess via std.process), background compression process, framerate clock, thread channel. AMQP runner stubbed as error-returning placeholder.",
    "files": [
      "src/infrastructure/tcp_server.zig",
      "src/infrastructure/shell_runner.zig",
      "src/infrastructure/channel.zig",
      "src/infrastructure/clock.zig",
      "src/infrastructure/persistence/background.zig",
      "src/infrastructure.zig"
    ],
    "tests": [
      "src/infrastructure/channel.zig",
      "src/infrastructure/clock.zig"
    ],
    "dependencies": ["domain_types", "persistence_codec", "protocol_parser"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test --test-filter infrastructure",
      "expected_output": "All 0 tests passed.",
      "build_command": "zig build"
    }
  },
  {
    "name": "interfaces_entry_point",
    "project": "",
    "layer": "interfaces",
    "description": "CLI entry point (main.zig): argument parsing (-c/--config), TOML configuration loading with defaults, component wiring (spawn Controller, Database, Processor threads), message routing loop between execution channels.",
    "files": [
      "src/interfaces/cli.zig",
      "src/interfaces/config.zig",
      "src/interfaces.zig",
      "src/main.zig",
      "build.zig",
      "build.zig.zon"
    ],
    "tests": [
      "src/interfaces/config.zig"
    ],
    "dependencies": ["domain_types", "application_scheduler", "infrastructure_adapters"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test",
      "expected_output": "All 0 tests passed.",
      "build_command": "zig build -Doptimize=ReleaseSafe"
    }
  }
]
```

## Test Plan

```yaml
unit_tests:
  scope: "Per component, co-located in source files"
  naming: "test blocks inside each .zig file"
  requirements:
    - "domain/job.zig: set/get, get_to_execute with time filtering, sequential modifications (port 3 Rust tests)"
    - "domain/rule.zig: supports() pattern matching with weight, non-matching patterns"
    - "infrastructure/persistence/encoder.zig: encode/decode round-trip for Job and Rule, all Runner variants, invalid data errors (port 2 Rust tests)"
    - "infrastructure/persistence/logfile.zig: length-prefixed encode/parse, incomplete buffers, max size errors (port 2 Rust tests)"
    - "infrastructure/protocol/parser.zig: valid KCP lines, simple/quoted strings, escape sequences, incomplete/invalid buffers (port 1 Rust test with 13 assertions)"
    - "application/job_storage.zig: storage operations, status filtering, ordered insertion"
    - "application/rule_storage.zig: rule CRUD, pattern pairing with priority"
    - "infrastructure/channel.zig: send/receive, blocking behavior"
    - "interfaces/config.zig: TOML parsing, defaults, validation"

functional_tests:
  scope: "End-to-end behavior via tests/ directory"
  naming: "tests/integration_*.zig"
  requirements:
    - "Scheduler tick loop: set job, advance time, verify triggered status"
    - "Persistence round-trip: write entries, reinitialize storage, verify state restored"
    - "Protocol end-to-end: raw KCP buffer -> parsed instruction -> query response"

coverage_targets:
  domain: "95%+"
  overall: "80%+"
```

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Binary persistence format incompatibility with Rust version | Med | P0 | Port all encoder test vectors byte-for-byte from Rust tests (`encoder.rs:270-326`). Validate with actual Rust-generated logfiles. | Developer |
| KCP protocol parser edge cases missed | Med | P1 | Port all 13 assertion cases from `parser.rs:67-121`. Add fuzz testing for malformed input. | Developer |
| Thread channel correctness (replacing crossbeam) | Low | P1 | Use `std.testing.allocator` for leak detection. Stress test with concurrent producers/consumers. | Developer |
| TOML parser too limited for future config extensions | Low | P2 | Current config only uses flat sections with primitive values. If complex TOML needed later, vendor a C parser via `@cImport`. | Developer |
| Zig 0.14.1 stdlib API changes in future versions | Low | P2 | Pin Zig version in CI (`mlugg/setup-zig@v2` with `version: 0.14.1`). Document stdlib APIs used. | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| `kairoi/` submodule | Reference implementation no longer needed after Zig port is validated | Remove git submodule (after validation) |
| 5x duplicated Runner enum in Rust | Consolidation into single `src/domain/runner.zig` | Not carried forward (clean slate) |
| 23 `panic!()` calls in Rust | Replaced with proper Zig error propagation | Not carried forward |
| 20+ `unwrap()` calls in Rust | Replaced with `try` keyword | Not carried forward |
| 1 `unsafe` block (`from_utf8_unchecked`) | Safe UTF-8 validation in Zig via `std.unicode` | Not carried forward |
| 4 `@TODO` comments in Rust | Addressed as first-class implementations: proper channel disconnection handling, connection lifecycle management, streaming compressed entry reads | Implemented properly in Zig |
