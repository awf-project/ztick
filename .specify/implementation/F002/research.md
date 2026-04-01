# Research: F002 — QUERY Command for Pattern-Based Job Lookup

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig (0.14.1) |
| Domain | CLI / TCP job scheduler |
| Task Type | feature |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: F001 (GET command) is IMPLEMENTED and merged (PR #4). F002 is blocked by F001 — dependency satisfied. Key ADRs: optional body field on Response (ADR #11), cross-layer ownership transfer (ADR #13), read-only instructions skip persistence (ADR #14), `@tagName` for enum serialization (ADR #15). Implementation patterns: exhaustive switch cascade for new tagged union variants (pattern #13), `std.fmt.allocPrint` for dynamic formatting (pattern #15), socketpair for TCP tests (pattern #16).

**Sources**: `memory/feature_roadmap.md`, `memory/architecture_decisions.md`, `memory/implementation_patterns.md`, `memory/test_conventions.md`

**Recommendation**: Follow the exact same layer-by-layer approach used in F001. The Response.body field exists; the main design decision is whether to keep `?[]const u8` (pre-formatted multi-line string) or change to `?[][]const u8` (slice of strings). The spec's Key Entities table suggests the latter, but keeping `?[]const u8` with newline-separated lines is simpler and avoids changing the Response struct used by GET.

---

### Q1: [ARCH] What patterns should F002 follow?

**Finding**: The codebase uses strict hexagonal architecture with 4 layers (domain → application → infrastructure → interfaces) connected via barrel exports. F001 GET is the direct reference implementation. The implementation path is:

1. **Domain** (`src/domain/instruction.zig`): Add `query: struct { pattern: []const u8 }` variant to `Instruction` union
2. **Application** (`src/application/query_handler.zig`): Add `.query` arm to `handle()` — iterate JobStorage hashmap with `std.mem.startsWith()` prefix matching, format multi-line body
3. **Application** (`src/application/scheduler.zig`): Add `.query => return` to `append_to_logfile()` (read-only, no persistence per FR-006)
4. **Infrastructure** (`src/infrastructure/tcp_server.zig`): Add QUERY parsing in `build_instruction()`, add `.query` arm to `free_instruction_strings()`, extend `write_response()` for multi-line format
5. **Infrastructure** (`src/infrastructure/persistence/encoder.zig`): No changes needed (QUERY is read-only, same as GET precedent at line 6)

Key design decision: **Multi-line response format**. The spec requires `<request_id> <job_id> <status> <execution_ns>\n` per match, terminated by `<request_id> OK\n`. Current `write_response()` formats `<request_id> OK <body>\n` for GET. This needs refactoring to support the QUERY format where each data line and the terminal OK are separate writes.

**Error handling note**: FR-005 requires `<request_id> ERROR` for missing pattern argument. Current `build_instruction()` returns null for invalid commands, which silently discards. Must ensure ERROR response is sent for QUERY without pattern.

**Sources**: `src/domain/instruction.zig:4-17`, `src/application/query_handler.zig:25-53`, `src/application/scheduler.zig:86-114`, `src/infrastructure/tcp_server.zig:205-259,321-342,344-352`

**Recommendation**: Follow GET's layer-by-layer approach. For multi-line response, use `body: ?[]const u8` with newline-separated content (e.g., `"job.1 planned 123\njob.2 executed 456"`) and refactor `write_response()` to emit each line prefixed with request_id, then a terminal `<request_id> OK\n`. This avoids changing the Response struct type while supporting multi-line output.

---

### Q2: [TYPES] Which types can F002 reuse?

**Finding**: F002 reuses nearly all existing types:

| Type | Location | Reuse |
|------|----------|-------|
| `Instruction` union | `src/domain/instruction.zig:4-17` | Add `query` variant with `pattern: []const u8` |
| `Request` struct | `src/domain/query.zig:6-10` | Reuse as-is (carries Instruction) |
| `Response` struct | `src/domain/query.zig:12-16` | Reuse `body: ?[]const u8` for multi-line payload |
| `Job` struct | `src/domain/job.zig:3-14` | Read fields: `identifier`, `status`, `execution` |
| `JobStatus` enum | `src/domain/job.zig:3-7` | Use `@tagName()` for string serialization |
| `JobStorage` | `src/application/job_storage.zig:7-78` | Iterate `jobs` hashmap via `valueIterator()` |
| `QueryHandler` | `src/application/query_handler.zig:12-53` | Add `.query` arm to `handle()` |
| `Rule.supports()` | `src/domain/rule.zig:11-16` | Pattern for prefix matching: `std.mem.startsWith()` |

No new types needed beyond the `query` variant struct. JobStorage may benefit from a `get_by_prefix(pattern, allocator) ![]Job` method for clean separation, following the `get_by_status()` pattern at lines 65-77.

**Sources**: All files listed above

**Recommendation**: Add `query` variant to Instruction. Add `get_by_prefix()` to JobStorage following `get_by_status()` pattern. Keep Response.body as `?[]const u8`. Use `@tagName(job.status)` for status serialization (ADR #15).

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Test patterns to follow for F002:

1. **Domain unit tests** (`src/domain/instruction.zig`): Add test for `query` variant — verify tag via `std.meta.activeTag()`, verify pattern via `expectEqualStrings()`. Follow existing set/get test style at lines 19-42.

2. **QueryHandler tests** (`src/application/query_handler.zig`): Use GPA with full lifecycle. Create jobs via storage, invoke `handler.handle()` with `.query` instruction, verify `.success` and `.body` content. Caller frees body with `defer if (response.body) |b| allocator.free(b)`. Test cases: prefix match (single, multiple), no match (success + null body or empty body), empty pattern (all jobs).

3. **JobStorage tests** (`src/application/job_storage.zig`): If adding `get_by_prefix()`, test with GPA. Return owned `[]Job` slice, caller frees. Test empty prefix (all), matching prefix, non-matching prefix.

4. **TCP server tests** (`src/infrastructure/tcp_server.zig`):
   - `build_instruction`: Test QUERY parsing with 2+ args, verify pattern duped. Test null return for missing pattern. Use `std.testing.allocator` + `defer free_instruction_strings()`.
   - `write_response`: Use socketpair (`std.os.linux.socketpair`) to test multi-line output format. Verify each line has request_id prefix and terminal OK.

5. **Functional tests** (`src/functional_tests.zig`): SET multiple jobs with distinct prefixes → QUERY prefix → verify response body contains matching jobs. Follow SET-then-GET round-trip pattern at lines 16-261. Test cases per spec: US1 (prefix match), US2 (empty pattern = all), US3 (no match = OK only).

6. **Memory**: Use `std.testing.allocator` for simple tests, GPA for storage tests, arena for bulk decode. Always `defer` free response bodies.

**Sources**: `src/domain/instruction.zig:19-42`, `src/application/query_handler.zig:56-162`, `src/application/job_storage.zig:80-152`, `src/infrastructure/tcp_server.zig:416-476`, `src/functional_tests.zig:16-261`

**Recommendation**: Follow existing test patterns exactly. Minimum test coverage: instruction creation, handler dispatch (match/no-match/multi-match), build_instruction parsing, write_response multi-line format, and one functional SET→QUERY round-trip.

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: F001 (GET command) was implemented in PR #4 (commit `83e2eb9`) and merged to main. Key decisions from F001 that carry forward:

1. **Response.body as `?[]const u8`**: Chosen over separate GetResponse type or tagged union (ADR #11). Backward compatible via null default.
2. **String duplication at parse time**: All instruction args are `allocator.dupe()`'d in `build_instruction()`, not borrowed.
3. **Memory ownership refactoring**: `is_borrowed_by_instruction()` and `free_unused_args()` were deleted during F001 (observation 16801). Current model: explicit duplication, no pointer-equality tracking.
4. **Read-only persistence skip**: GET uses `.get => return` in `append_to_logfile()`. QUERY follows same pattern.
5. **197 tests passing**: Full test suite validated after F001 merge.

The F002 branch (`feature/F002-query-command-for-pattern-based-job-look`) exists but has no commits beyond main.

**Sources**: PR #4, git log, `.specify/implementation/F002/` (spec-content.md, spec.json, context.json)

**Recommendation**: F002 is ready to implement with no blockers. All F001 patterns are established and tested.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**:

1. **Stale spec reference (FR-007)**: FR-007 references `is_borrowed_by_instruction()` which was deleted during F001 refactoring. The function no longer exists. `free_instruction_strings()` does exist and needs a `.query` arm, but the FR-007 wording about `is_borrowed_by_instruction()` is outdated.
   - **Source**: spec-content.md line 99 — SPEC_MISMATCH [Risk: Low]
   - **Action**: Ignore the `is_borrowed_by_instruction()` reference; only implement `free_instruction_strings()` handling.

2. **No dead code detected**: All functions in the codebase are referenced. No TODO/FIXME/HACK markers found in any .zig files.

3. **Memory ownership is clean**: Post-F001 refactoring removed all borrowed-string tracking. Current pattern (explicit duplication) is consistent across the codebase.

4. **Minor optimization opportunity**: `tcp_server.zig:161-163` manually frees parser args in a loop; could use `defer result.deinit()` instead. Low priority, not related to F002.

**Sources**: `src/infrastructure/tcp_server.zig:321-342`, spec-content.md FR-007

**Recommendation**: No cleanup required before F002 implementation. Note that FR-007's reference to `is_borrowed_by_instruction()` is stale — only `free_instruction_strings()` needs a `.query` arm.

---

## Best Practices

| Pattern | Application in F002 |
|---------|----------------------------|
| Exhaustive switch cascade | Adding `query` variant triggers compiler errors at all switch sites — fix domain → application → infrastructure |
| Cross-layer ownership transfer | QueryHandler allocates body string, TCP server frees after `write_response()` |
| Prefix matching via `std.mem.startsWith` | Reuse Rule.supports() semantics for job identifier prefix matching |
| `@tagName()` for enum serialization | Use `@tagName(job.status)` to produce status strings in response lines |
| `allocator.dupe()` at parse boundary | Duplicate pattern string in `build_instruction()`, own until scheduler consumes |
| `errdefer` cleanup chains | If QUERY parsing involves multiple allocations, use errdefer for each |
| Optional field with null default | Response.body stays `?[]const u8 = null`, QUERY populates with multi-line string |
| socketpair for TCP tests | Test write_response multi-line format with `std.os.linux.socketpair` |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| Zig stdlib | 0.14.1 | All functionality (zero external deps) | installed | none |

## References

| File | Relevance |
|------|-----------|
| `src/domain/instruction.zig` | Add `query` variant to Instruction tagged union |
| `src/domain/query.zig` | Response struct with body field (reuse as-is) |
| `src/domain/job.zig` | Job entity with identifier, status, execution fields |
| `src/domain/rule.zig` | `supports()` method — prefix matching reference implementation |
| `src/application/query_handler.zig` | Add `.query` dispatch arm to `handle()` |
| `src/application/job_storage.zig` | Add `get_by_prefix()` or iterate hashmap for prefix matching |
| `src/application/scheduler.zig` | Add `.query => return` to `append_to_logfile()` |
| `src/infrastructure/tcp_server.zig` | Parse QUERY, free strings, write multi-line response |
| `src/infrastructure/persistence/encoder.zig` | No changes needed (read-only precedent at line 6) |
| `src/functional_tests.zig` | Add SET→QUERY round-trip integration tests |
