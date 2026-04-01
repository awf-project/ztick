# Implementation Plan: F002

## Summary

Add a `QUERY <pattern>` command to the ztick TCP protocol that returns all jobs whose identifier starts with the given prefix. Implementation follows the GET command (F001) layer-by-layer pattern: add `query` variant to `Instruction`, extend `QueryHandler` with prefix-match iteration over `JobStorage`, update TCP server parsing/response/cleanup, and add functional tests for single-match, multi-match, and no-match scenarios.

## Constitution Compliance

Constitution: Derived from CLAUDE.md

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal layering (domain → application → infrastructure) | COMPLIANT | Changes propagate domain → application → infrastructure, no cross-layer violations |
| Tagged unions for protocol types | COMPLIANT | `query` variant added to `Instruction` tagged union |
| Barrel exports only | COMPLIANT | All imports go through `domain.zig`, `application.zig`, `infrastructure.zig` |
| Co-located unit tests | COMPLIANT | Tests added within each modified source file |
| Exhaustive switch coverage | COMPLIANT | Zig compiler enforces all switch sites handle new `query` variant |
| String duplication at parse boundary | COMPLIANT | Pattern string `allocator.dupe()`'d in `build_instruction()` |
| Read-only commands skip persistence | COMPLIANT | `.query => return` in `append_to_logfile()`, matching `.get => return` |
| Per-connection response channels | COMPLIANT | No changes to response routing — QUERY uses same request/response flow |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.14.x (stdlib only, zero deps) |
| Framework | None (custom TCP server) |
| Architecture | Hexagonal — domain / application / infrastructure / interfaces |
| Key patterns | Tagged union exhaustive switches, `allocator.dupe()` at parse, `allocPrint` for response body, `@tagName()` for enum serialization, socketpair for TCP tests |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | Response.body type: `?[]const u8` (single string) vs `?[][]const u8` (slice of strings) | Keep `?[]const u8` with newline-separated lines. QueryHandler formats the entire multi-line body as a single allocated string. | `src/domain/query.zig:15` — body is `?[]const u8 = null`; changing the type would break GET responses |
| A2 | Multi-line response wire format: who prepends request_id to each line? | `write_response()` handles formatting. For QUERY, the body contains raw `<job_id> <status> <exec_ns>\n` lines; `write_response()` prepends request_id to each line and appends terminal `<request_id> OK\n`. | `src/infrastructure/tcp_server.zig:344-352` — current `write_response()` already formats request_id + status + body |
| A3 | Should `get_by_prefix()` be a new method on JobStorage? | Yes — follows `get_by_status()` pattern for clean separation and testability. Returns `[]Job` owned slice, caller frees. | `src/application/job_storage.zig:65-77` — `get_by_status()` uses same `valueIterator()` + filter + `toOwnedSlice()` pattern |
| A4 | How to handle `QUERY` with no pattern argument (FR-005)? | Return `null` from `build_instruction()` — the TCP server already sends no response for unrecognized commands. However, FR-005 requires ERROR. Must add explicit error response path. | `src/infrastructure/tcp_server.zig:205-259` — `build_instruction()` returns `null` for invalid commands; `tcp_server.zig:189-191` shows null result calls `result.deinit(allocator)` with no response sent |
| A5 | Empty pattern `QUERY ""` — how does quoted empty string parse? | The existing parser handles quoted strings and returns the unquoted content. `QUERY ""` yields pattern `""` which is empty string after unquoting. `std.mem.startsWith(u8, anything, "")` returns true, matching all jobs (US2). | `src/infrastructure/protocol/parser.zig` — quoted string support exists; `std.mem.startsWith` with empty prefix always returns true per Zig stdlib |

## Approach Comparison

| Criteria | Approach A: Body-as-string | Approach B: Body-as-slice | Approach C: Streaming per-job writes |
|----------|---------------------------|--------------------------|--------------------------------------|
| Description | QueryHandler formats multi-line body as single `[]const u8`, refactor `write_response()` to split on newlines and prefix each line | Change `Response.body` to `?[][]const u8`, each element is one job line | QueryHandler returns job iterator, TCP server writes each job directly to stream |
| Files touched | 5 | 6 (+ all existing body consumers) | 5 |
| New abstractions | 0 | 0 | 1 (iterator type) |
| Risk level | Low | Med (breaks GET response handling) | High (changes ownership model) |
| Reversibility | Easy | Hard (type change cascades) | Hard (architectural shift) |

**Selected: Approach A**
**Rationale:** Keeps `Response.body` as `?[]const u8` — zero impact on GET command. The only refactoring needed is in `write_response()` to handle multi-line bodies by splitting on `\n` and prefixing each line with request_id. QueryHandler does the heavy lifting of formatting.
**Trade-off accepted:** Body string is allocated as one block (slightly more memory than streaming), but job count is bounded by resident storage so this is negligible.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| Add `get_by_prefix()` to JobStorage | Follows `get_by_status()` pattern; keeps prefix matching logic in application layer, testable without TCP | Inline iteration in QueryHandler — harder to test, violates single responsibility |
| Refactor `write_response()` for multi-line | QUERY needs `<request_id> <data>\n` per match line + `<request_id> OK\n` terminal. Current format is `<request_id> OK <body>\n`. Must distinguish single-line (GET) from multi-line (QUERY) responses. | Separate `write_query_response()` — duplicates formatting logic |
| FR-005 ERROR for missing pattern via explicit check in `build_instruction()` | Current null-return silently drops invalid commands. QUERY without pattern must return ERROR per spec. Will add a sentinel error instruction or handle inline. | Returning success=false from QueryHandler — too late, build_instruction already discarded the command |
| Body format: `"<job_id> <status> <exec_ns>\n..."` without request_id | Request_id is a transport concern. QueryHandler produces domain-level body; `write_response()` prepends request_id per line. | Embedding request_id in body — mixes transport with domain |

## Components

```json
[
  {
    "name": "instruction_query_variant",
    "project": "",
    "layer": "domain",
    "description": "Add query variant with pattern field to Instruction tagged union",
    "files": ["src/domain/instruction.zig"],
    "tests": ["src/domain/instruction.zig"],
    "dependencies": [],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-domain --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "job_storage_prefix_lookup",
    "project": "",
    "layer": "application",
    "description": "Add get_by_prefix() method to JobStorage using valueIterator and std.mem.startsWith for prefix matching, returning owned []Job slice",
    "files": ["src/application/job_storage.zig"],
    "tests": ["src/application/job_storage.zig"],
    "dependencies": ["instruction_query_variant"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-application --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "query_handler_dispatch",
    "project": "",
    "layer": "application",
    "description": "Add .query arm to QueryHandler.handle() — call get_by_prefix(), format multi-line body with allocPrint using @tagName(status) and execution timestamp per matching job, return Response with body",
    "files": ["src/application/query_handler.zig", "src/application/scheduler.zig"],
    "tests": ["src/application/query_handler.zig", "src/application/scheduler.zig"],
    "dependencies": ["instruction_query_variant", "job_storage_prefix_lookup"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-application --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "tcp_server_query_support",
    "project": "",
    "layer": "infrastructure",
    "description": "Parse QUERY command in build_instruction(), add .query arm to free_instruction_strings(), refactor write_response() to handle multi-line body format with per-line request_id prefix, handle FR-005 missing pattern ERROR",
    "files": ["src/infrastructure/tcp_server.zig"],
    "tests": ["src/infrastructure/tcp_server.zig"],
    "dependencies": ["instruction_query_variant"],
    "user_story": "US1, US3",
    "verification": {
      "test_command": "zig build test-infrastructure --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "functional_query_tests",
    "project": "",
    "layer": "infrastructure",
    "description": "End-to-end SET → QUERY round-trip tests: prefix match returning multiple jobs, no-match returning OK only, empty pattern returning all jobs",
    "files": ["src/functional_tests.zig"],
    "tests": ["src/functional_tests.zig"],
    "dependencies": ["query_handler_dispatch", "tcp_server_query_support"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-functional --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  }
]
```

## Test Plan

### Unit Tests

**instruction.zig** — `test "query instruction stores pattern"`: verify tag is `.query`, pattern is correct via `expectEqualStrings`.

**job_storage.zig** — 3 tests:
- `test "get_by_prefix returns jobs matching prefix"`: SET backup.daily, backup.weekly, deploy.prod → prefix "backup." returns 2 jobs
- `test "get_by_prefix returns empty slice for no match"`: prefix "nonexistent." returns 0-length slice
- `test "get_by_prefix with empty prefix returns all jobs"`: empty string returns all stored jobs

**query_handler.zig** — 3 tests:
- `test "handle query instruction returns matching jobs in body"`: SET 2 jobs with same prefix → QUERY returns body with 2 lines
- `test "handle query instruction returns success with null body for no matches"`: QUERY non-matching prefix → success=true, body=null
- `test "handle query instruction returns all jobs for empty pattern"`: SET 3 jobs → QUERY "" returns body with 3 lines

**scheduler.zig** — 2 tests:
- `test "handle_query with query instruction returns matching jobs"`: round-trip through scheduler
- `test "handle_query with query instruction does not persist to logfile"`: verify file size unchanged after QUERY (matching `.get` no-persist test pattern)

**tcp_server.zig** — 3 tests:
- `test "build_instruction parses QUERY command with pattern"`: verify `.query` variant with duped pattern
- `test "build_instruction returns null for QUERY without pattern"`: FR-005 missing argument handling
- `test "write_response formats multi-line body with request_id prefix"`: socketpair test verifying `<id> <data>\n...<id> OK\n` format

### Functional Tests

**functional_tests.zig** — 3 tests:
- `test "query with prefix returns matching jobs"`: SET backup.daily + backup.weekly + deploy.prod → QUERY backup. → verify 2 data lines + OK
- `test "query with no matches returns OK only"`: SET jobs → QUERY nonexistent. → verify only OK line
- `test "query with empty pattern returns all jobs"`: SET 3 jobs → QUERY "" → verify 3 data lines + OK

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| `write_response()` refactor breaks existing GET response format | Med | P0 | GET test coverage already exists (unit + functional); run full test suite after refactor. GET uses single-line body so detection is via `\n` count in body. | Developer |
| Hashmap iteration order is non-deterministic | Low | P1 | Tests must not assert on line ordering — use set-based comparison (collect lines, sort, compare). Spec explicitly defers sorted results. | Developer |
| FR-005 ERROR response for missing pattern requires new code path | Low | P1 | Current `build_instruction()` returns null for invalid commands, silently dropping them. Must either add error response inline or introduce an error instruction variant. Simplest: check for QUERY with <2 args, write ERROR directly. | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| FR-007 spec reference to `is_borrowed_by_instruction()` | Function was deleted during F001 refactoring; spec text is stale | Update spec-content.md FR-007 to reference only `free_instruction_strings()` |
