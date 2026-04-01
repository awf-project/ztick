# Research: F007 - Logfile Dump Command

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig |
| Domain | CLI subcommand |
| Task Type | feature |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: Project memories confirm all features C001-F006 are IMPLEMENTED. Key patterns relevant to F007:
- **Binary codec pattern** (pattern #6): Length-prefixed entries with type byte discriminators, big-endian encoding. Round-trip tested. The dump command directly consumes this.
- **Streaming parser pattern** (pattern #5): Protocol parser handles incomplete buffers, returns partial results. Logfile parser follows same approach with `ParseResult.remaining`.
- **Inside-out layered development** (pattern #7): Build domain first, then application, infrastructure, interfaces. F007 should follow this.
- **Process-based functional tests** (pattern #34-35): Spawn ztick as child process, capture stderr, use non-blocking pipe reads. Dump command tests should use this pattern for CLI output verification.
- **Persist-before-respond** (ADR #25): Removal entries follow SET pattern. The dump command must correctly decode all 4 entry types (job, rule, job_removal, rule_removal).
- **Compressor exclusion pattern** (pattern #23): When last entry for an ID is removal, skip entirely during compression. The `--compact` mode must replicate this behavior.
- **Zero external dependencies** (ADR #2): F007 must use only Zig stdlib. No JSON libraries — hand-write NDJSON output.

**Sources**: implementation_patterns.md, architecture_decisions.md, test_conventions.md, feature_roadmap.md
**Recommendation**: Reuse existing persistence infrastructure (logfile.parse + encoder.decode) directly. Follow process-based test pattern for functional tests. Implement compact mode using same logic as scheduler.replay_entry().

---

### Q1: [ARCH] What patterns should F007 follow?

**Finding**: The project uses strict 4-layer hexagonal architecture with barrel exports:
- **domain/** — Pure types (Job, Rule, Runner, Instruction, Query, Execution)
- **application/** — State machines, storage (Scheduler, JobStorage, RuleStorage, QueryHandler)
- **infrastructure/** — I/O adapters (TCP server, persistence, protocol parser, TLS)
- **interfaces/** — CLI entry point, config, wiring (cli.zig, config.zig, main.zig)

Current CLI parsing in `interfaces/cli.zig` is minimal — only handles `--config/-c` flags. Main entry point (`main.zig:432+`) directly spawns 3 threads assuming server mode. The dump command needs early dispatch before server initialization.

Key reference implementations:
1. **scheduler.load()** (`application/scheduler.zig:46-79`): Shows exact pattern for reading and decoding logfile — open file, readToEndAlloc, parse frames, decode entries, replay.
2. **query_handler.zig**: Shows handler pattern with allocator, storage references, switch on instruction type.

**Sources**: `src/interfaces/cli.zig:11-25`, `src/main.zig:432-507`, `src/application/scheduler.zig:46-79`
**Recommendation**: Create `src/interfaces/dump.zig` for dump command logic. Extend `interfaces/cli.zig` Args to detect `dump` as first positional argument. Add early dispatch in main.zig before config loading and thread spawning. Register in `src/interfaces.zig` barrel file.

---

### Q2: [TYPES] Which types can F007 reuse?

**Finding**: All critical types for F007 already exist:

| Type | File | Purpose for F007 |
|------|------|-----------------|
| `Entry` (tagged union) | `src/infrastructure/persistence/encoder.zig:6-13` | Core type — 4 variants: job, rule, job_removal, rule_removal |
| `Job` | `src/domain/job.zig:10-14` | Fields: identifier, execution (i64), status (JobStatus enum) |
| `Rule` | `src/domain/rule.zig:6-9` | Fields: identifier, pattern, runner (Runner union) |
| `Runner` | `src/domain/runner.zig:1-10` | Tagged union: shell{command} or amqp{dsn, exchange, routing_key} |
| `JobStatus` | `src/domain/job.zig:3-8` | Enum: planned, triggered, executed, failed |
| `ParseResult` | `src/infrastructure/persistence/logfile.zig:16-19` | Struct: entries ([][]u8), remaining ([]const u8) |
| `DecodeError` | `src/infrastructure/persistence/encoder.zig:4` | error{InvalidData} |
| `ParseError` | `src/infrastructure/persistence/logfile.zig:6` | error{CorruptedContent, Incomplete} |

Key functions to reuse:
- `persistence.logfile.parse(allocator, data)` — frame parsing
- `persistence.encoder.decode(allocator, frame_data)` — entry decoding
- `persistence.encoder.free_entry_fields(entry, allocator)` — cleanup after decode

New types needed:
- `DumpOptions` struct: logfile_path, format (text/json), compact (bool), follow (bool)
- `DumpCommand` enum or tagged union for CLI dispatch: `{ server, dump: DumpOptions }`

**Sources**: `src/infrastructure/persistence/encoder.zig:6-13`, `src/domain/job.zig:3-14`, `src/domain/rule.zig:6-9`, `src/domain/runner.zig:1-10`, `src/infrastructure/persistence/logfile.zig:16-19`
**Recommendation**: Reuse Entry, Job, Rule, Runner, ParseResult directly. Create DumpOptions in interfaces layer. No domain or application layer changes needed — dump is a pure infrastructure/interfaces feature.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Testing follows established patterns:

1. **Unit tests**: Co-located in source files via `test` blocks. Use `std.heap.GeneralPurposeAllocator` or `std.testing.allocator`. Descriptive names ("tick transitions planned job to triggered when rule matches").

2. **CLI parsing tests**: Use `Args.parse_slice(&.{ "dump", "logfile.bin" })` pattern to test argument parsing with both success and error cases (`src/interfaces/cli.zig:38-63`).

3. **Binary codec round-trip tests**: Encode known entries, verify byte sequences, decode back and compare fields. Use `std.testing.allocator` with deferred cleanup (`src/infrastructure/persistence/encoder.zig:244-369`).

4. **Functional tests**: Process-based testing in `src/functional_tests.zig` using `TestServer` helper that manages tmpdir, config files, child process lifecycle. Non-blocking stderr draining via `fcntl` + `O.NONBLOCK` (`src/functional_tests.zig:641-751`).

5. **Build targets**: `test-domain`, `test-application`, `test-infrastructure`, `test-interfaces`, `test-functional`, `test-all` defined in `build.zig:40-92`.

6. **Logfile building helper**: `build_logfile_bytes()` in functional_tests.zig creates test logfiles from Entry arrays — directly reusable for F007 tests (`src/functional_tests.zig:159-191`).

**Sources**: `src/functional_tests.zig:159-191, 641-751`, `src/interfaces/cli.zig:38-63`, `src/infrastructure/persistence/encoder.zig:244-369`, `build.zig:40-92`
**Recommendation**: F007 tests should include:
- Unit tests in `src/interfaces/dump.zig` for CLI arg parsing and output formatting
- Functional tests in `src/functional_tests.zig` for end-to-end dump command (spawn process, create logfile, run dump, compare stdout)
- Reuse `build_logfile_bytes()` helper to create test logfiles with known entries
- Use `std.testing.tmpDir` for temporary logfile creation in tests

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: Git history and feature evolution reveal:

1. **Feature branch pattern**: `feature/F007-logfile-dump-command` (already created, at same commit as main). Commit style: `feat(category): description`.

2. **CLI evolution**: Currently handles only `--config/-c`. First subcommand (`dump`) is a new architectural pattern — no prior subcommand exists.

3. **Entry format stability**: Binary format (type bytes 0-3, u16 length-prefixed strings, i64 timestamps, u8 status) has been stable since C001. No version negotiation needed — validates spec assumption.

4. **Protocol command vs CLI-only**: F001-F004 added protocol commands (GET, QUERY, REMOVE, LISTRULES) touching instruction.zig, query_handler.zig, tcp_server.zig. F007 is CLI-only — does NOT touch protocol layer. This is a different implementation path.

5. **Scheduler.load() as reference**: The load pattern (`scheduler.zig:46-79`) is the closest existing code to what dump needs — file open, readToEndAlloc, parse frames, decode entries. Error handling: `catch continue` for malformed frames.

6. **Background compressor**: `background.zig:72-115` implements deduplication by tracking last entry per ID and filtering removals — same logic needed for `--compact`.

**Sources**: Git log (commits ce00863, c2955e6, 29f7073, 0dade52), `src/application/scheduler.zig:46-79`, `src/infrastructure/persistence/background.zig:72-115`
**Recommendation**: Follow the scheduler.load() pattern for file reading and decoding. Use background.zig compress() logic as template for --compact deduplication. Do NOT touch any protocol layer files (instruction.zig, query_handler.zig, tcp_server.zig).

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: No dead code to delete. Cleanup opportunities are preparation items for F007:

| Item | File | Category | Risk |
|------|------|----------|------|
| `deprecatedWriter()` usage | `src/main.zig:58` | DEPRECATION | MEDIUM |
| Server-only assumption in main() | `src/main.zig:432-507` | ARCHITECTURE | HIGH |
| Server-only CLI parsing | `src/interfaces/cli.zig:8-35` | ARCHITECTURE | HIGH |
| Private decode helpers not reusable | `src/infrastructure/persistence/encoder.zig:209` | CODE REUSE | MEDIUM |
| Deduplication tightly coupled to background.zig | `src/infrastructure/persistence/background.zig:72-115` | CODE REUSE | LOW-MEDIUM |

**Sources**: `src/main.zig:58, 432-507`, `src/interfaces/cli.zig:8-35`, `src/infrastructure/persistence/encoder.zig:209`, `src/infrastructure/persistence/background.zig:72-115`
**Recommendation**: Required refactoring for F007:
1. Extend CLI parsing to support subcommand dispatch (HIGH priority)
2. Add early dispatch in main() before server initialization (HIGH priority)
3. Consider making `read_sized_string()` public if dump needs direct string extraction (MEDIUM, evaluate during implementation)
4. Do NOT extract deduplication into shared module — implement compact mode independently in dump.zig, keeping it simple (spec notes: "reuse same approach as background.zig compressor")

## Best Practices

| Pattern | Application in F007 |
|---------|----------------------------|
| Inside-out layered development | No domain/application changes needed. Add interfaces/dump.zig + update infrastructure barrel if needed |
| Streaming parser with remaining bytes | Use logfile.parse() which returns ParseResult.remaining for partial frame handling |
| Arena allocator for decoded entries | Allocate decoded Entry fields in arena; single deinit at end |
| Process-based functional tests | Spawn `ztick dump <logfile>` as child process, capture stdout, compare output |
| Exhaustive switch on tagged union | Switch on Entry variants for text/JSON formatting — compiler catches missing types |
| Error union over panics | Return errors for file not found, permission denied; never @panic |
| Set-before-spawn for config | Not applicable — dump runs single-threaded, no thread spawning needed |
| Read-only file access | Open logfile read-only (FR-011) allowing concurrent use while ztick server runs |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| Zig stdlib | 0.14.0+ | All I/O, memory, formatting | installed | none |

No external dependencies required (NFR-004). JSON output hand-written using std.io.Writer.

## References

| File | Relevance |
|------|-----------|
| `src/application/scheduler.zig:46-79` | Reference implementation for logfile loading pattern (open, read, parse, decode) |
| `src/infrastructure/persistence/encoder.zig` | Entry type definition, encode/decode functions, binary format |
| `src/infrastructure/persistence/logfile.zig` | Frame parsing (4-byte length prefix), ParseResult with remaining bytes |
| `src/infrastructure/persistence/background.zig:72-115` | Deduplication logic template for --compact mode |
| `src/interfaces/cli.zig` | Current CLI parsing — needs extension for subcommand dispatch |
| `src/main.zig:432-507` | Entry point — needs early dispatch for dump vs server mode |
| `src/functional_tests.zig:159-191` | build_logfile_bytes() and replay_into_scheduler() helpers for test logfile creation |
| `src/functional_tests.zig:641-751` | TestServer pattern and process spawning for functional tests |
| `src/application/query_handler.zig:47,62,81-82` | Text output format reference for job/rule formatting |
| `src/interfaces.zig` | Barrel export file — needs dump.zig registration |
