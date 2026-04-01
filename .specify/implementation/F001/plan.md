# Implementation Plan: F001

## Summary

Wire the existing `GET <id>` protocol command through the instruction → query handler → response chain by adding a `get` variant to `Instruction`, extending `Response` with an optional `body` field, and formatting job state (status + execution timestamp) as the response payload. The `QueryHandler` allocates the body string; the TCP server frees it after writing.

## Constitution Compliance

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal Architecture | COMPLIANT | Changes follow domain → application → infrastructure layering; no upward dependencies introduced |
| TDD Methodology | COMPLIANT | Unit tests in query_handler.zig, functional test in functional_tests.zig; domain + application coverage maintained |
| Zig Idioms | COMPLIANT | Error unions for allocation, `@tagName` for enum serialization, `std.fmt.allocPrint` for body formatting |
| Minimal Abstraction | COMPLIANT | Reuses existing Response struct with optional field rather than introducing new types; no new abstractions |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.14.x |
| Framework | stdlib only (zero deps) |
| Architecture | Hexagonal (domain / application / infrastructure / interfaces) |
| Key patterns | Tagged unions for instruction dispatch, exhaustive switches enforced by compiler, ownership transfer across channel boundary, co-located unit tests |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | Response body format for GET is not specified in protocol docs | Use `<status> <execution_ns>` format matching spec's acceptance criteria: `<request_id> OK <status> <execution_ns>\n` | `spec-content.md:31` — acceptance criteria defines exact format |
| A2 | Who allocates and frees the response body string | QueryHandler allocates via `std.fmt.allocPrint`, TCP server frees after `write_response()` | `tcp_server.zig:181` — existing pattern where TCP server frees `resp.request.identifier` after write |
| A3 | Whether GET instruction identifier is borrowed or owned | Borrowed from parser args, same as `set.identifier` — pointer comparison in `is_borrowed_by_instruction` | `tcp_server.zig:313` — `set` variant checks `arg.ptr == s.identifier.ptr` |
| A4 | Whether `handle_query` should skip persistence for GET | Yes — GET is read-only, must not call `append_to_logfile` | `scheduler.zig:90-94` — persistence only runs on `response.success`, but GET success shouldn't persist; need explicit skip |
| A5 | What allocator QueryHandler uses for body formatting | QueryHandler currently takes no allocator; must add allocator parameter to `handle()` or store on struct | `query_handler.zig:23` — `handle` takes only `Request`, no allocator available for allocation |

## Approach Comparison

| Criteria | Approach A: Allocator on QueryHandler struct | Approach B: Allocator parameter to handle() | Approach C: Pre-allocated fixed buffer |
|----------|----------------------------------------------|---------------------------------------------|---------------------------------------|
| Description | Store allocator on QueryHandler, use it in handle() for body allocation | Add allocator param to handle() signature | Use stack buffer in handle(), copy to response |
| Files touched | 6 | 6 | 6 |
| New abstractions | 0 | 0 | 0 |
| Risk level | Low | Low | Med (buffer size limits) |
| Reversibility | Easy | Easy | Easy |

**Selected: Approach A**
**Rationale:** QueryHandler already stores pointers to storages — adding an allocator follows the same pattern and avoids changing every call site's signature. The allocator is needed for `std.fmt.allocPrint` to format the body string. Zig convention is to pass allocator as parameter to functions that allocate, but since QueryHandler is a stateful struct initialized once, storing it on the struct is idiomatic (matches `JobStorage` pattern at `job_storage.zig:8`).
**Trade-off accepted:** Approach B would make the allocation dependency more explicit per-call, but scheduler.zig already constructs QueryHandler with storage pointers, so adding allocator there is natural and avoids changing handle()'s signature which is called from scheduler.zig:88.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| Add `body: ?[]const u8 = null` to Response | Default null preserves backward compatibility for SET/RULE_SET responses; no existing code needs changes | Separate GetResponse type — would require second response channel or tagged union at transport layer |
| Store allocator on QueryHandler struct | Needed for `allocPrint` in GET handler; follows existing pattern of struct-stored dependencies | Pass allocator to handle() — changes signature at all call sites |
| Skip GET in scheduler.handle_query before append_to_logfile | GET is read-only; must not generate persistence entries | Check instruction type inside append_to_logfile — would still enter the function unnecessarily |
| Use `@tagName(job.status)` for status serialization | Built-in Zig reflection produces lowercase enum name matching spec format (planned/triggered/executed/failed) | Manual switch with string literals — redundant given enum names already match |
| Free response body in TCP server after write_response | Ownership transfer pattern: allocator in QueryHandler, consumer in TCP server — matches existing pattern of freeing request.identifier after write | Free in scheduler — would require scheduler to know about transport concerns |

## Components

```json
[
  {
    "name": "extend_domain_types",
    "project": "",
    "layer": "domain",
    "description": "Add get variant to Instruction tagged union and body field to Response struct",
    "files": [
      "src/domain/instruction.zig",
      "src/domain/query.zig"
    ],
    "tests": [
      "src/domain/instruction.zig",
      "src/domain/query.zig"
    ],
    "dependencies": [],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-domain",
      "expected_output": "PASS (no test failures)",
      "build_command": "zig build"
    }
  },
  {
    "name": "handle_get_instruction",
    "project": "",
    "layer": "application",
    "description": "Add allocator to QueryHandler, handle .get in handle() by looking up job and formatting body as 'status execution_ns', skip GET in scheduler persistence",
    "files": [
      "src/application/query_handler.zig",
      "src/application/scheduler.zig"
    ],
    "tests": [
      "src/application/query_handler.zig",
      "src/application/scheduler.zig"
    ],
    "dependencies": ["extend_domain_types"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-application",
      "expected_output": "PASS (no test failures)",
      "build_command": "zig build"
    }
  },
  {
    "name": "wire_tcp_protocol",
    "project": "",
    "layer": "infrastructure",
    "description": "Parse GET command in build_instruction(), add get arms to is_borrowed_by_instruction() and free_instruction_strings(), extend write_response() to append body after OK",
    "files": [
      "src/infrastructure/tcp_server.zig"
    ],
    "tests": [
      "src/infrastructure/tcp_server.zig"
    ],
    "dependencies": ["extend_domain_types"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-infrastructure",
      "expected_output": "PASS (no test failures)",
      "build_command": "zig build"
    }
  },
  {
    "name": "functional_test_and_docs",
    "project": "",
    "layer": "infrastructure",
    "description": "Add SET-then-GET round-trip functional test, update protocol docs to move GET from unimplemented to documented",
    "files": [
      "src/functional_tests.zig",
      "docs/reference/protocol.md"
    ],
    "tests": [
      "src/functional_tests.zig"
    ],
    "dependencies": ["handle_get_instruction", "wire_tcp_protocol"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-functional",
      "expected_output": "PASS (no test failures)",
      "build_command": "zig build"
    }
  }
]
```

## Test Plan

### unit_tests

**query_handler.zig — GET existing job returns success with body:**
- SET a job into storage, then send GET request
- Assert `response.success == true`
- Assert `response.body` contains `"planned 1595586600000000000"`
- Free body with allocator after assertion

**query_handler.zig — GET missing job returns failure:**
- Send GET request for nonexistent identifier
- Assert `response.success == false`
- Assert `response.body == null`

**tcp_server.zig — build_instruction recognizes GET command:**
- Existing test pattern verifies instruction parsing (covered by compiler exhaustive switch enforcement)

### functional_tests

**functional_tests.zig — SET then GET round-trip:**
- Create scheduler, SET a job via `handle_query()`
- Send GET request via `handle_query()`
- Assert response success and body format matches `"planned <execution_ns>"`
- Verify response body memory is properly allocated (freed in test with defer)

**functional_tests.zig — GET nonexistent job returns error:**
- Create scheduler (no jobs)
- Send GET request via `handle_query()`
- Assert `response.success == false` and `response.body == null`

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Exhaustive switch compilation errors cascade across many files when adding Instruction variant | High | P1 | Compiler enforces all switch sites — address each in dependency order (domain → application → infrastructure) | Developer |
| Response body memory leak if TCP server doesn't free after write | Med | P1 | Add explicit `defer allocator.free(body)` in handle_connection after write_response; test with GPA leak detection | Developer |
| QueryHandler allocator addition breaks existing test setup | Low | P0 | All existing QueryHandler tests must pass allocator; straightforward addition to init() calls | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| `docs/reference/protocol.md:135-142` | GET moves from unimplemented to implemented | Move to Commands section with full syntax |
| `docs/user-guide/creating-jobs.md:149-154` | GET no longer a limitation | Remove GET from limitations list |
