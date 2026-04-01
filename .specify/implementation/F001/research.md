# Research: F001 - Add GET command to ztick protocol

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig 0.14.x |
| Domain | CLI / TCP scheduler |
| Task Type | feature |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: Claude-mem observations 16726 and 16727 contain detailed prior analysis of the GET command implementation path. The instruction flow was traced: TCP server `build_instruction()` -> `Instruction` union -> `QueryHandler.handle()` -> `JobStorage.get()` -> `Response` back to TCP client. Key constraint identified: `append_to_logfile()` in scheduler switches on instruction type and must explicitly skip the `get` variant since GET is read-only. The `JobStorage.get()` method already exists and returns `?Job`. Observation 16713 confirms an implementation plan was previously created at `.agent/todo/add-get-command.md`. Serena memories returned empty (no project memories stored).

**Sources**: claude-mem observations 16709, 16711, 16712, 16713, 16726, 16727

**Recommendation**: Leverage the existing `JobStorage.get()` method. Focus implementation on wiring protocol -> instruction -> query handler -> response chain. Ensure `append_to_logfile()` skips GET.

---

### Q1: [ARCH] What patterns should F001 follow?

**Finding**: The codebase follows strict hexagonal architecture with 4 layers. The instruction processing flow is:

1. `tcp_server.zig:build_instruction()` (line 202-236) parses protocol text into `Instruction` variant
2. `tcp_server.zig:is_borrowed_by_instruction()` (line 311-332) tracks memory ownership of parsed args
3. `tcp_server.zig:free_instruction_strings()` (line 335-353) frees owned strings
4. `query_handler.zig:handle()` (line 23-46) processes instruction via switch, calls storage
5. `scheduler.zig:handle_query()` (line 86-97) delegates to QueryHandler, conditionally persists
6. `scheduler.zig:append_to_logfile()` (line 99-132) encodes successful mutations to logfile
7. `tcp_server.zig:write_response()` (line 355-360) formats `<request_id> OK|ERROR\n`

Memory ownership pattern: TCP server parses args, `build_instruction` borrows pointers into instruction, `free_unused_args` frees non-borrowed args, instruction strings transfer ownership to scheduler storage. For GET, the response body must be allocated by QueryHandler, transferred via Response, and freed by TCP server after `write_response()`.

**Sources**: `src/infrastructure/tcp_server.zig`, `src/application/query_handler.zig`, `src/application/scheduler.zig`, `src/infrastructure/persistence/encoder.zig`

**Recommendation**: Follow the exact same pattern as SET for instruction parsing and memory management. Add `get` variant to Instruction, extend Response with optional `body: ?[]const u8`, and add arms to all switch statements that exhaustively match on Instruction variants (build_instruction, is_borrowed_by_instruction, free_instruction_strings, QueryHandler.handle, append_to_logfile).

---

### Q2: [TYPES] Which types can F001 reuse?

**Finding**: Key types to reuse and extend:

| Type | Location | Action |
|------|----------|--------|
| `Instruction` (tagged union) | `src/domain/instruction.zig:4-14` | ADD `get: struct { identifier: []const u8 }` variant |
| `Response` (struct) | `src/domain/query.zig:12-15` | ADD `body: ?[]const u8 = null` field |
| `Request` (struct) | `src/domain/query.zig:6-10` | REUSE as-is (client, identifier, instruction) |
| `Job` (struct) | `src/domain/job.zig:10-14` | REUSE (identifier, execution: i64, status: JobStatus) |
| `JobStatus` (enum) | `src/domain/job.zig:3-8` | REUSE (planned=0, triggered=1, executed=2, failed=3) |
| `JobStorage.get()` | `src/application/job_storage.zig:25-27` | CALL (returns `?Job`) |
| `Client` (type alias) | `src/domain/query.zig:4` | REUSE (u128) |

Memory patterns:
- `Job.identifier` is borrowed (owned by JobStorage), never free when Job is copied out
- `Response.body` will be owned string allocated by QueryHandler, freed by TCP server after `write_response()`
- Instruction variant identifiers are borrowed from TCP parsing args

**Sources**: `src/domain/instruction.zig`, `src/domain/query.zig`, `src/domain/job.zig`, `src/application/job_storage.zig`

**Recommendation**: Add `get` variant with single `identifier` field. Add `body` field to Response with `= null` default for backward compatibility. Use `@tagName(status)` to convert JobStatus enum to string for response body formatting.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Tests follow these patterns:

1. **Co-located unit tests** in source files with descriptive names: `test "verb object expected outcome"`
2. **Allocator setup**: `GeneralPurposeAllocator` for integration, `std.testing.allocator` for simple unit tests
3. **Storage initialization**: `JobStorage.init(allocator)` + `RuleStorage.init(allocator)` with defer deinit
4. **Request construction**: Inline struct literal with all fields (client, identifier, instruction)
5. **Assertions**: `std.testing.expect()` for non-null, `expectEqual()` for exact match, `expectEqualStrings()` for strings
6. **Functional tests** in `src/functional_tests.zig`: Create scheduler, send requests via `scheduler.handle_query()`, verify storage state
7. **Build targets**: `test-application` for QueryHandler, `test-infrastructure` for tcp_server, `test-functional` for round-trips, `test-all` for everything

New tests needed:
- Unit in `query_handler.zig`: GET existing job -> success with body containing status + timestamp
- Unit in `query_handler.zig`: GET missing job -> failure with null body
- Functional in `functional_tests.zig`: SET then GET round-trip verifying response format

**Sources**: `src/functional_tests.zig`, `src/application/query_handler.zig`, `src/infrastructure/tcp_server.zig`, `build.zig`

**Recommendation**: Add 2 unit tests in query_handler.zig following existing pattern (GPA allocator, storage init, handler init, request construction, response verification). Add 1 functional test in functional_tests.zig following SET test pattern but verifying response.body content.

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: GET was never partially implemented. It exists only in documentation as a planned feature. The single initial commit (a626740) implemented SET and RULE SET with GET explicitly listed as unimplemented.

Documentation references found:
- `docs/reference/protocol.md:135-142` — "Unimplemented Commands" section lists GET, QUERY, REMOVE, REMOVERULE, LISTRULES
- `docs/user-guide/creating-jobs.md:149-154` — Lists GET as a limitation
- `docs/reference/README.md:32` — Shows intended syntax: `GET <id>`
- `docs/user-guide/README.md:40` — Shows example: `echo 'GET my.job' | nc localhost 5678`

No prior implementation attempts, no branches, no design debates in git history. The response format for GET is specified in the F001 spec: `<request_id> OK <status> <execution_ns>\n`.

**Sources**: `docs/reference/protocol.md`, `docs/user-guide/creating-jobs.md`, `docs/reference/README.md`, git log

**Recommendation**: Follow the response format from the spec. After implementation, update the protocol documentation to move GET from "Unimplemented Commands" to the main "Commands" section.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: No dead code, unused imports, TODO/FIXME comments, or disabled tests found in the affected files. Cleanup opportunities are documentation-only and pattern-related:

1. **IMMEDIATE** (required for F001 completion):
   - `docs/reference/protocol.md:135-142` — Remove GET from "Unimplemented Commands" section, add to main "Commands" section
   - `docs/user-guide/creating-jobs.md:149-154` — Remove GET from "Limitations" section

2. **DEFERRED** (recommended before adding QUERY/REMOVE):
   - `tcp_server.zig:311-353` — `is_borrowed_by_instruction()` and `free_instruction_strings()` have parallel switch structures that grow with each new instruction variant. Consider extracting instruction metadata helper before adding more commands.
   - `query_handler.zig:23-46` — Identical error handling patterns for SET and RULE_SET could be consolidated once 3+ variants exist.

**Sources**: `docs/reference/protocol.md`, `docs/user-guide/creating-jobs.md`, `src/infrastructure/tcp_server.zig`

**Recommendation**: Update documentation as part of F001. Defer code pattern consolidation — current duplication is acceptable for 3 instruction variants (set, rule_set, get).

## Best Practices

| Pattern | Application in F001 |
|---------|----------------------------|
| Tagged union exhaustive switch | All switch statements on `Instruction` must handle `.get` — compiler enforces this |
| Optional body with null default | `body: ?[]const u8 = null` on Response preserves backward compatibility for SET/RULE_SET |
| Ownership transfer across channel | QueryHandler allocates body string, TCP server frees it after write_response() |
| Read-only instruction skip | GET must not trigger `append_to_logfile()` — add explicit skip in scheduler switch |
| `@tagName` for enum serialization | Convert `JobStatus` enum to string for response body formatting |
| `std.fmt.allocPrint` for body | Allocate formatted body string: `"{s} {d}"` with status name and execution timestamp |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| zig stdlib | 0.14.x | All functionality | installed | none |

No external dependencies. Zero-dep project per ADR-0002.

## References

| File | Relevance |
|------|-----------|
| `src/domain/instruction.zig` | Add `get` variant to Instruction tagged union |
| `src/domain/query.zig` | Add `body: ?[]const u8 = null` to Response struct |
| `src/domain/job.zig` | Job struct and JobStatus enum — data source for GET response |
| `src/application/job_storage.zig` | `get()` method returns `?Job` — already implemented |
| `src/application/query_handler.zig` | Add `.get` arm to `handle()` switch — core business logic |
| `src/application/scheduler.zig` | Skip `.get` in `append_to_logfile()` — read-only invariant |
| `src/infrastructure/tcp_server.zig` | Parse GET, manage memory, format response with body |
| `src/infrastructure/persistence/encoder.zig` | No changes needed if scheduler skips GET before encoding |
| `src/functional_tests.zig` | Add SET-then-GET round-trip test |
| `docs/reference/protocol.md` | Move GET from unimplemented to documented |
| `docs/user-guide/creating-jobs.md` | Remove GET from limitations |
