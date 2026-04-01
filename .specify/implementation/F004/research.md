# Research: F004 — Add LISTRULES Command

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig 0.14.x |
| Domain | CLI / TCP protocol scheduler |
| Task Type | Feature (read-only protocol command) |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: No Serena memories exist. Project memory files (feature_roadmap.md, architecture_decisions.md, implementation_patterns.md, test_conventions.md) document established patterns from C001 through F003. Key ADRs relevant to LISTRULES:
- ADR-16 (F002): Multi-line body formatting uses single `[]const u8` with newline separators, not slice of strings. `write_response()` splits on `\n` and prefixes request_id per line.
- ADR-12/15/17: Cross-layer ownership transfer — QueryHandler allocates body string, TCP server frees after write_response().
- ADR-13: Exhaustive switch checking on tagged unions catches all update points at compile time.

**Sources**: `/home/pocky/.claude/projects/-home-pocky-Sites-pocky-ztick/memory/architecture_decisions.md`, `implementation_patterns.md`, `test_conventions.md`

**Recommendation**: Follow QUERY (F002) as the primary reference implementation. LISTRULES is structurally identical to QUERY: read-only, multi-line response, no persistence writes.

---

### Q1: [ARCH] What patterns should F004 follow?

**Finding**: LISTRULES implementation spans all 4 hexagonal layers, following the exact same flow as QUERY:

1. **Domain** (`src/domain/instruction.zig`): Add `.list_rules` variant to `Instruction` union(enum) with empty struct payload (no fields needed — read-only, no arguments).
2. **Application** (`src/application/query_handler.zig`): Add `.list_rules` match arm in `QueryHandler.handle()` that iterates `rule_storage.rules.valueIterator()`, formats each rule as `"<id> <pattern> <runner_type> <runner_args>\n"` into an `ArrayListUnmanaged(u8)` body buffer.
3. **Application** (`src/application/scheduler.zig`): Add `.list_rules` to the read-only no-persist group in `append_to_logfile()` alongside `.get` and `.query`.
4. **Infrastructure** (`src/infrastructure/tcp_server.zig`):
   - `build_instruction()`: Parse `LISTRULES` command string, return `.list_rules` instruction.
   - `write_response()`: Extend multi-line response formatting to handle `.list_rules` same as `.query`.
   - `free_instruction_strings()`: Add `.list_rules` arm (no-op, no owned strings).
   - Error handling block (lines 203-206): Add `LISTRULES` recognition.

**Sources**: `src/infrastructure/tcp_server.zig:229-267` (build_instruction), `src/application/query_handler.zig:50-66` (QUERY handler), `src/application/scheduler.zig:86-115` (handle_query + append_to_logfile)

**Recommendation**: Mirror QUERY end-to-end. Compiler exhaustive switch checking will enforce all dispatch points are updated.

---

### Q2: [TYPES] Which types can F004 reuse?

**Finding**: All necessary types already exist — no new types needed beyond the instruction variant:

| Type | Location | Usage in LISTRULES |
|------|----------|-------------------|
| `Instruction` (union(enum)) | `src/domain/instruction.zig:4-26` | Add `.list_rules: struct {}` variant |
| `Rule` (struct) | `src/domain/rule.zig:6-17` | Fields: identifier, pattern, runner — iterated for response |
| `Runner` (union(enum)) | `src/domain/runner.zig:1-10` | Variants: shell{command}, amqp{dsn, exchange, routing_key} — serialized per FR-005 |
| `RuleStorage` (struct) | `src/application/rule_storage.zig:7-50` | Use `rules.valueIterator()` to iterate all rules |
| `Request` (struct) | `src/domain/query.zig:6-10` | Wraps instruction with client ID and request identifier |
| `Response` (struct) | `src/domain/query.zig:12-16` | Return type: success + optional body containing rule lines |
| `ParseResult` (struct) | `src/infrastructure/protocol/parser.zig:5-15` | Existing parser handles LISTRULES tokenization |

**Sources**: All files listed above.

**Recommendation**: Reuse all existing types. The only new code artifact is the `.list_rules` variant added to the `Instruction` union.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Three test layers with established patterns:

1. **Parser tests** (`src/infrastructure/protocol/parser.zig:101-193`): Call `parse()` with full command lines including `\n` terminator, verify command and args via `expectEqual`, test both success and error cases with `expectError`.

2. **Handler tests** (`src/application/query_handler.zig:184-239`): Initialize JobStorage + RuleStorage, create QueryHandler, construct Request with instruction variant, call `handler.handle(request)`, verify `response.success` and `response.body`. Use `defer if (response.body) |b| allocator.free(b)` for cleanup.

3. **Functional tests** (`src/functional_tests.zig:321-364`): End-to-end round-trip tests — SET rules via protocol, send LISTRULES, verify multi-line response. Split body on `\n`, count non-empty lines, verify content with `std.mem.indexOf`. Use `GeneralPurposeAllocator` with leak checking.

**Key patterns**:
- Response body built with `ArrayListUnmanaged(u8)` + `writer().print()` + `toOwnedSlice()`
- Multi-line response tested by splitting on `\n` and checking line count
- Test naming: `"handle_query with list_rules instruction [scenario]"`
- Empty result: `success=true`, `body=null`
- Non-deterministic hash map iteration: sort output lines before comparison if order matters

**Sources**: `src/functional_tests.zig`, `src/application/query_handler.zig`, `src/infrastructure/protocol/parser.zig`

**Recommendation**: Add co-located unit tests in query_handler.zig for list_rules handling, parser tests for LISTRULES command parsing, and functional tests for RULE SET → LISTRULES round-trip.

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: Strong reference implementations from recent features:

- **F002 (QUERY, commit cfdff95)**: Closest model. Established multi-line response pattern, read-only instruction handling, `get_by_prefix()` iteration, body formatting with allocPrint, and `write_response()` multi-line splitting.
- **F003 (REMOVE/REMOVERULE, commit 1e4333e)**: Most recent feature. Shows how to add new instruction variants, extend exhaustive switches, and update error handling blocks. Mutating command (unlike LISTRULES) but same structural pattern for adding new protocol commands.
- **Exhaustive switch propagation**: Adding `.list_rules` to `Instruction` union triggers compile errors at every unhandled switch, ensuring all dispatch points are updated. This is the primary correctness mechanism.

**Sources**: Commits `cfdff95` (F002), `1e4333e` (F003), memory files (architecture_decisions.md, implementation_patterns.md)

**Recommendation**: Follow F002 QUERY implementation exactly. Use F003 as reference for the mechanical steps of adding a new instruction variant across all switch statements.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: No dead code or deprecated patterns to remove. Minor consolidation opportunities identified but not recommended for F004 scope:

1. **write_response() branching** (`src/infrastructure/tcp_server.zig:399-429`): Currently special-cases `.query` for multi-line formatting. LISTRULES will add a second case. Refactoring to a shared multi-line formatter could reduce duplication but is premature with only 2 commands.

2. **build_instruction() if-chain** (`src/infrastructure/tcp_server.zig:229-267`): Sequential `std.mem.eql` checks for each command. Could become a dispatch table but is maintainable at 7 commands.

3. **Error handling block** (`src/infrastructure/tcp_server.zig:203-206`): Must be extended to include LISTRULES recognition.

**Sources**: `src/infrastructure/tcp_server.zig:203-206`, `src/infrastructure/tcp_server.zig:229-267`, `src/infrastructure/tcp_server.zig:399-429`

**Recommendation**: No cleanup needed before or during F004. Extend existing patterns rather than refactoring. The codebase is clean for the current command count.

---

## Best Practices

| Pattern | Application in F004 |
|---------|---------------------|
| Exhaustive switch on tagged union | Adding `.list_rules` to `Instruction` forces compile-time errors at every unhandled dispatch point |
| Cross-layer ownership transfer | QueryHandler allocates response body, TCP server frees after `write_response()` |
| Multi-line body as single string | Build `"line1\nline2\n"` in handler, `write_response()` splits and prefixes request_id per line |
| Read-only skip persistence | Add `.list_rules` to `append_to_logfile()` return-early group alongside `.get`, `.query` |
| Runner tag formatting | Use `switch` on `rule.runner` to format shell vs amqp fields per FR-005 |
| ArrayListUnmanaged body buffer | Use `writer().print()` for each rule line, `toOwnedSlice()` for final body |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| (none) | - | Zero external dependencies per project constraint | installed | none |

## References

| File | Relevance |
|------|-----------|
| `src/domain/instruction.zig` | Add `.list_rules` variant to Instruction union |
| `src/domain/rule.zig` | Rule struct (identifier, pattern, runner) — iterated for response |
| `src/domain/runner.zig` | Runner union (shell, amqp) — formatted per FR-005 |
| `src/domain/query.zig` | Request/Response types reused for LISTRULES |
| `src/application/rule_storage.zig` | RuleStorage with `rules.valueIterator()` for iteration |
| `src/application/query_handler.zig` | QueryHandler.handle() — add `.list_rules` arm (primary implementation site) |
| `src/application/scheduler.zig` | `append_to_logfile()` — add `.list_rules` to read-only skip group |
| `src/infrastructure/tcp_server.zig` | `build_instruction()`, `write_response()`, `free_instruction_strings()`, error handling |
| `src/infrastructure/protocol/parser.zig` | Existing parser handles tokenization — no changes needed |
| `src/functional_tests.zig` | Add RULE SET → LISTRULES round-trip functional tests |
