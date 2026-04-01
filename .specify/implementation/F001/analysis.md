ARTIFACT_ANALYSIS

## Findings

| ID | Category | Severity | Location | Summary | Recommendation |
|----|----------|----------|----------|---------|----------------|
| F1 | Coverage | CRITICAL | tasks:T008, scheduler.zig:99-113 | `append_to_logfile()` has an exhaustive switch over `Instruction` that will fail to compile when `.get` is added. T008 targets `encoder.zig` which only handles `Entry`, not `Instruction` — it will never encounter the new variant. T004's acceptance criteria says "GET instructions do not call append_to_logfile" (a runtime guard) but doesn't require the mandatory compile-time `get` arm in `append_to_logfile`'s switch. No task's acceptance criteria explicitly covers this arm. | Correct T008 to target `scheduler.zig:append_to_logfile()`, or add to T004's acceptance criteria: "get arm added to `append_to_logfile` switch (e.g., `get => return`)" |
| F2 | Coverage | HIGH | tasks:T008, encoder.zig | T008 says "Handle or skip `get` variant in `encoder.zig`" but `encoder.zig:encode()` operates on `Entry` (`.job`/`.rule`), not on `Instruction`. There is no switch over `Instruction` in this file; the task as written has no meaningful implementation target. | Redirect T008 to the real gap: the `.get` arm in `scheduler.zig:append_to_logfile()`. Encoder.zig requires no changes. |
| F3 | Underspecification | MEDIUM | plan:§Key Decisions, tasks:T007 | T007 says "body memory freed after write" but `write_response()` takes only `stream` and `resp` — it has no allocator. The free must happen at the call site in `handle_connection` (line 177), not inside `write_response()`. The task description implies the wrong function owns the deallocation. | Clarify T007 acceptance criteria: "After `write_response()` returns, `handle_connection` frees `resp.body` via the connection-scoped allocator." |
| F4 | Ambiguity | MEDIUM | spec:AC, plan:§Test Plan | `execution_ns` in the response body format (`<status> <execution_ns>`) is the *scheduled timestamp* stored in `Job.execution: i64`, not an execution duration. The abbreviation `_ns` typically denotes a duration. This will cause confusion when reading responses like `planned 1595586600000000000` — is that a schedule or how long it ran? | Rename to `scheduled_ns` in the response format spec, or add a clarifying note in the protocol docs task (T010). |
| F5 | Underspecification | LOW | plan:§wire_tcp_protocol, tcp_server.zig:358 | `write_response()` uses a 512-byte stack buffer with silent overflow (`catch return`). The extended format `"{s} OK {s}
"` adds body content (max ~26 chars for `"planned 1595586600000000000"`). With long request identifiers the buffer could silently truncate and return without writing. Plan doesn't flag this. | T007 acceptance criteria should note the 512-byte limit remains sufficient given max body length, or extend the buffer to 1024 bytes as a precaution. |
| F6 | Ordering | LOW | tasks:dependency graph, T001→T008 | The dependency graph shows T001→T008, implying T008 needs the new `Instruction.get` variant. But if T008 actually targets `encoder.zig` (which has no `Instruction` switch), the dependency is spurious. If corrected to `scheduler.zig:append_to_logfile`, T001→T008 is valid and required. | Fix in conjunction with F2 resolution. |

## Coverage Map

| Requirement | Has Task? | Task IDs | Notes |
|-------------|-----------|----------|-------|
| Add `.get` to `Instruction` | Yes | T001 | |
| Add `body: ?[]const u8 = null` to `Response` | Yes | T002 | |
| Handle `.get` in `QueryHandler.handle()` with allocator | Yes | T003 | |
| Pass allocator to `QueryHandler`, guard persistence for GET | Yes | T004 | Acceptance criteria covers runtime guard only; compile fix in `append_to_logfile` switch not explicitly required |
| Parse `GET` in `build_instruction()` | Yes | T005 | |
| Add `.get` arms to `is_borrowed_by_instruction()` and `free_instruction_strings()` | Yes | T006 | |
| Extend `write_response()` for non-null body; free body after write | Partial | T007 | Free location unspecified (see F3) |
| Add `.get` arm to `append_to_logfile()` switch in `scheduler.zig` | No | — | Gap: T008 targets wrong file (encoder.zig); T004 covers runtime guard only. Compile error guaranteed without this arm. |
| Unit test: GET existing job → success with body | Yes | T003 | |
| Unit test: GET missing job → failure, body null | Yes | T003 | |
| Functional test: SET→GET round-trip | Yes | T009 | |
| Protocol docs update | Yes | T010 | |
| AC: No persistence log entry for GET | Partial | T004, T008 | T004 guards call; T008 targets wrong file; exhaustive switch fix missing |
| AC: Response body memory freed by TCP server | Partial | T007 | Mechanism unclear (see F3) |
| AC: All existing tests pass | Implicit | All | |

## Metrics

- Total Requirements: 15
- Total Tasks: 10
- Coverage: 87% (13/15 requirements have ≥1 task)
- Critical Issues: 1
- High Issues: 1
- Ambiguities: 1
- Gaps: 2

## Verdict

CRITICAL_COUNT: 1
HIGH_COUNT: 1
COVERAGE_PERCENT: 87
RECOMMENDATION: REVIEW_NEEDED
