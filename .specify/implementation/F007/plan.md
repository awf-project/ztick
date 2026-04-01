# Implementation Plan: F007

## Summary

Add a `ztick dump <logfile_path>` CLI subcommand that reads the binary persistence logfile and prints decoded entries to stdout in human-readable text (default) or NDJSON format. The implementation extends the existing CLI parser with subcommand dispatch, creates a new `dump.zig` module in the interfaces layer, and reuses the existing `logfile.parse()` + `encoder.decode()` infrastructure for frame parsing and entry decoding.

## Constitution Compliance

Constitution: Derived from CLAUDE.md

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal layering (domain/application/infrastructure/interfaces) | COMPLIANT | dump.zig lives in interfaces layer; reuses infrastructure persistence modules through barrel imports |
| Tagged unions with `struct {}` payloads | COMPLIANT | Switch on existing `Entry` union (job, rule, job_removal, rule_removal) for formatting |
| Zero external dependencies (stdlib only) | COMPLIANT | JSON output hand-written with std.io.Writer; no JSON library |
| Barrel exports between layers | COMPLIANT | dump.zig added to `src/interfaces.zig`; imports persistence through `src/infrastructure.zig` barrel |
| Error unions for fallible operations | COMPLIANT | DumpError union for file-not-found, permission-denied; error propagation in main.zig |
| Co-located unit tests + functional_tests.zig | COMPLIANT | Unit tests in dump.zig; process-based functional tests in functional_tests.zig |
| snake_case functions, PascalCase types | COMPLIANT | DumpOptions, format_entry_text, format_entry_json, run_dump |
| Verbose test names describing behavior | COMPLIANT | e.g. "dump prints set entry as protocol command syntax" |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.14.0+ |
| Framework | None (stdlib only) |
| Architecture | Hexagonal 4-layer: domain, application, infrastructure, interfaces |
| Key patterns | Length-prefixed framing, tagged union dispatch, arena allocator for decoded entries, process-spawning functional tests |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | How to dispatch between server mode and dump subcommand | First positional argument check: if `args[0] == "dump"` → dump mode, else fall through to existing server behavior. No subcommand framework needed. | `cli.zig:11-25` currently treats all args as flags; `main.zig:437` calls `Args.parse()` before any server setup — early dispatch point exists |
| A2 | Text output format for entries | Match protocol command syntax exactly: `SET <id> <ts_ns> <status>`, `RULE SET <id> <pattern> <runner_type> [args...]`, `REMOVE <id>`, `REMOVERULE <id>` | `query_handler.zig:47,62,81-82` shows existing text formatting; FR-005 in spec defines exact format |
| A3 | How to stream entries without loading entire file | Use `file.readToEndAlloc()` (same as `scheduler.zig:56`) then `logfile.parse()`. Streaming frame-by-frame would require refactoring logfile.parse() which is out of scope. Memory bounded by file size for non-compact mode. | `scheduler.zig:46-57` reads entire file; `logfile.parse()` returns `ParseResult.remaining` for partial frame detection |
| A4 | Compact mode deduplication approach | Two-pass approach matching `background.zig:72-115`: first pass tracks last index per ID and flags removal IDs, second pass emits only entries at their last position whose ID is not removed | `background.zig:72-115` implements identical deduplication logic already |
| A5 | Follow mode file watching mechanism | Polling fallback using periodic `stat()` to detect file size changes, then read new bytes from last offset. No inotify/kqueue for initial delivery. | Spec assumption: "Follow mode can use a polling fallback (periodic stat check) as a minimum viable implementation" |
| A6 | How `Args.parse()` handles subcommand without breaking existing server mode | Extend Args to detect "dump" as first positional arg, collect remaining args as dump-specific. When no "dump" detected, existing `--config/-c` parsing applies unchanged. | `cli.zig:15-21` loop currently returns `UnknownFlag` on any non-flag arg — this is the insertion point |
| A7 | JSON field names and structure for NDJSON output | Use spec-defined fields: `type` (set/rule_set/remove/remove_rule), `identifier`, plus type-specific fields. Runner nested as `{"type":"shell","command":"..."}` or `{"type":"amqp","dsn":"...","exchange":"...","routing_key":"..."}` | FR-006 in spec defines exact schema; `encoder.zig:8-13` Entry variants map 1:1 to JSON type field values |

## Approach Comparison

| Criteria | Approach A: Extend cli.zig + new dump.zig | Approach B: Separate dump binary | Approach C: Dump as protocol command |
|----------|-------------------------------------------|----------------------------------|--------------------------------------|
| Description | Add subcommand dispatch to existing cli.zig, create interfaces/dump.zig for dump logic | Build a second binary `ztick-dump` with its own main | Add DUMP command to TCP protocol, query running server |
| Files touched | 4 modified + 1 new | 2 new + build.zig modified | 5+ modified (protocol, instruction, tcp_server, query_handler) |
| New abstractions | 1 (DumpOptions) | 2 (new main, DumpOptions) | 2+ (new instruction variant, new query handler branch) |
| Risk level | Low | Medium | High |
| Reversibility | Easy | Easy | Hard |

**Selected: Approach A**
**Rationale:** Single binary is the established pattern (`zig-out/bin/ztick`). Spec explicitly states "simple first-argument dispatch is sufficient" (Assumption section). Adding dump to the existing binary follows the Unix subcommand convention and requires minimal build system changes.
**Trade-off accepted:** cli.zig becomes slightly more complex with subcommand detection, but the alternative of maintaining two binaries is worse for distribution and documentation.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| Tagged union `Command` (server/dump) for CLI dispatch | Compiler enforces exhaustive handling in main.zig; fits project's tagged-union-everywhere pattern | Boolean flag `is_dump` — less extensible, doesn't carry DumpOptions |
| Hand-written JSON with std.fmt.bufPrint | Zero dependencies requirement (NFR-004); entry types are simple enough that a JSON library adds no value | Import/create JSON serializer — overkill for 4 entry types |
| Read entire file then parse (not streaming reads) | Reuses existing `logfile.parse()` unchanged; streaming would require new API. NFR-001 exempts compact mode; non-compact mode memory is bounded by file size. | New streaming parse API — significant refactor for marginal benefit on initial delivery |
| Follow mode uses poll loop with Thread.sleep | Simplest cross-platform approach; no inotify/kqueue dependency. Spec allows polling fallback. 1-second poll interval meets SC-004 (2-second detection target). | inotify — Linux-only, adds complexity; not needed for v1 |
| Compact mode re-implements dedup instead of extracting shared function from background.zig | background.zig operates on raw frames for file rewriting; dump needs decoded entries for formatting. Extraction would require restructuring background.zig for no other consumer. | Extract shared dedup module — premature abstraction, one consumer each |

## Components

```json
[
  {
    "name": "cli_subcommand_dispatch",
    "project": "",
    "layer": "interfaces",
    "description": "Extend Args in cli.zig to detect 'dump' as first positional argument, parse dump-specific flags (--format, --compact, --follow), and return a Command tagged union (server or dump with DumpOptions)",
    "files": ["src/interfaces/cli.zig"],
    "tests": ["src/interfaces/cli.zig"],
    "dependencies": [],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-interfaces",
      "expected_output": "All 0 passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "entry_formatter",
    "project": "",
    "layer": "interfaces",
    "description": "Create dump.zig with functions to format a decoded Entry as text (protocol command syntax) and as NDJSON (one JSON object per line). Text: 'SET id ts status', 'RULE SET id pattern runner_type args', 'REMOVE id', 'REMOVERULE id'. JSON: {type, identifier, ...type-specific fields}",
    "files": ["src/interfaces/dump.zig"],
    "tests": ["src/interfaces/dump.zig"],
    "dependencies": [],
    "user_story": "US1, US2",
    "verification": {
      "test_command": "zig build test-interfaces",
      "expected_output": "All 0 passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "dump_command_runner",
    "project": "",
    "layer": "interfaces",
    "description": "Implement run_dump() in dump.zig: open logfile read-only, read contents, parse frames via logfile.parse(), decode entries via encoder.decode(), write formatted output to stdout. Handle errors (file not found, permission denied) with stderr message and exit code 1. Handle partial trailing frames with stderr warning and continue. Support --compact mode with two-pass deduplication.",
    "files": ["src/interfaces/dump.zig"],
    "tests": ["src/interfaces/dump.zig"],
    "dependencies": ["cli_subcommand_dispatch", "entry_formatter"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-interfaces",
      "expected_output": "All 0 passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "follow_mode",
    "project": "",
    "layer": "interfaces",
    "description": "Implement --follow flag in dump.zig: after initial dump, poll file for size changes using stat() with 1-second sleep interval. Read new bytes from last offset, parse and format new entries. Exit cleanly on SIGINT/SIGTERM.",
    "files": ["src/interfaces/dump.zig"],
    "tests": ["src/interfaces/dump.zig"],
    "dependencies": ["dump_command_runner"],
    "user_story": "US4",
    "verification": {
      "test_command": "zig build test-interfaces",
      "expected_output": "All 0 passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "main_dispatch_integration",
    "project": "",
    "layer": "interfaces",
    "description": "Wire dump command into main.zig: parse Args to get Command, switch on command — for .dump invoke dump.run_dump(), for .server run existing server logic. Register dump.zig in interfaces.zig barrel. Update build.zig if needed for test discovery.",
    "files": ["src/main.zig", "src/interfaces.zig"],
    "tests": ["src/main.zig"],
    "dependencies": ["cli_subcommand_dispatch", "dump_command_runner"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test",
      "expected_output": "All 0 passed",
      "build_command": "zig build"
    }
  },
  {
    "name": "functional_tests_dump",
    "project": "",
    "layer": "interfaces",
    "description": "Process-based functional tests in functional_tests.zig: build logfile with known entries using build_logfile_bytes(), write to tmpdir, spawn 'ztick dump <path>' as child process, capture stdout, compare output line-by-line for text and JSON formats. Test compact mode, empty file, missing file error, and partial frame warning.",
    "files": ["src/functional_tests.zig"],
    "tests": ["src/functional_tests.zig"],
    "dependencies": ["main_dispatch_integration"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-functional",
      "expected_output": "All 0 passed",
      "build_command": "zig build"
    }
  }
]
```

## Test Plan

### Unit Tests (co-located in source files)

**src/interfaces/cli.zig:**
- `parse_slice` with `dump logfile.bin` returns dump command with default options
- `parse_slice` with `dump logfile.bin --format json` returns json format
- `parse_slice` with `dump logfile.bin --compact` returns compact true
- `parse_slice` with `dump logfile.bin --follow` returns follow true
- `parse_slice` with `dump logfile.bin --format json --compact --follow` combines all flags
- `parse_slice` with `dump` (no path) returns MissingValue error
- `parse_slice` with `dump logfile.bin --format xml` returns InvalidValue error
- `parse_slice` with no args returns server command (backward compat)
- `parse_slice` with `--config path` returns server command with config (backward compat)

**src/interfaces/dump.zig:**
- format_entry_text for job entry produces `SET <id> <ts> <status>`
- format_entry_text for rule entry with shell runner produces `RULE SET <id> <pattern> shell <command>`
- format_entry_text for rule entry with amqp runner produces `RULE SET <id> <pattern> amqp <dsn> <exchange> <routing_key>`
- format_entry_text for job_removal produces `REMOVE <id>`
- format_entry_text for rule_removal produces `REMOVERULE <id>`
- format_entry_json for job entry produces valid JSON with type, identifier, execution, status
- format_entry_json for rule entry with shell runner produces JSON with nested runner object
- format_entry_json for rule entry with amqp runner produces JSON with nested runner object
- format_entry_json for job_removal produces JSON with type and identifier only
- format_entry_json for rule_removal produces JSON with type and identifier only

### Functional Tests (src/functional_tests.zig)

- dump prints all entries in text format from logfile with mixed entry types
- dump prints all entries in json format and each line is valid JSON
- dump with --compact deduplicates entries keeping last SET per identifier
- dump with --compact omits entries whose final mutation is a removal
- dump on empty logfile produces no output and exits 0
- dump on missing logfile prints error to stderr and exits 1
- dump on logfile with partial trailing frame prints warning to stderr and outputs complete entries

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Follow mode signal handling (SIGINT) may not work reliably across platforms | Medium | P1 | Implement with `std.posix.sigaction` for SIGINT; test manually. Fallback: document Ctrl+C behavior. | Developer |
| Memory usage for large logfiles in non-streaming mode | Low | P2 | Spec says "streaming" but existing `readToEndAlloc` pattern is established. Document file size limits. Add streaming in future iteration if needed. | Developer |
| CLI arg parsing refactor breaks existing server mode | Medium | P1 | Comprehensive backward-compatibility tests: no args → server, `--config path` → server. Run full test suite after refactor. | Developer |
| `deprecatedWriter()` in main.zig log_fn may break in future Zig versions | Low | P2 | Not in F007 scope but worth noting. Filed as known tech debt. | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| `CliError.UnknownFlag` handling in cli.zig | After subcommand dispatch, first positional arg is no longer "unknown flag" — it's either "dump" or treated as server mode | Refactor: remove UnknownFlag for positional args, keep for actual unknown flags like `--verbose` |
| `main.zig:58` deprecatedWriter() | Pre-existing deprecation, not caused by F007 | No action in F007 scope — document as future cleanup |
