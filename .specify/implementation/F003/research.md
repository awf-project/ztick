# Research: F003 — REMOVE and REMOVERULE Commands

## Detection Context

| Property | Value |
|----------|-------|
| Language | Zig 0.14.x |
| Domain | CLI / TCP scheduler |
| Task Type | feature |

## Questions Investigated

### Q0: [MEMORY] What do project memories tell us?

**Finding**: Claude-mem observations #16901 and #16903 provide direct context. REMOVE and REMOVERULE are documented as unimplemented in `docs/reference/protocol.md` — the server currently silently ignores these commands. The LISTRULES research (#16903) mapped the full four-layer architecture: domain instructions → application query handlers → infrastructure TCP server → persistence encoder. The QUERY command implementation (F002) established the architectural template for adding new protocol commands. RuleStorage already has a `delete()` method returning `bool`. Read-only commands (GET, QUERY) skip logfile persistence; REMOVE/REMOVERULE are mutations and must persist.

**Sources**: claude-mem #16901, #16903; Serena memories: none available (empty)

**Recommendation**: Follow the F001 (GET) and F002 (QUERY) implementation pattern across all four layers. REMOVE/REMOVERULE are closest to GET structurally (single identifier argument) but closest to SET behaviorally (mutation + persistence).

---

### Q1: [ARCH] What patterns should F003 follow?

**Finding**: The codebase follows strict hexagonal architecture with four layers. F003 must touch all layers:

1. **Domain** (`src/domain/instruction.zig:4-20`): Add `.remove` and `.remove_rule` variants to the `Instruction` tagged union, each with a single `identifier: []const u8` field
2. **Application** (`src/application/query_handler.zig:25-71`): Add handler cases in the `handle()` switch to call `job_storage.delete()` and `rule_storage.delete()`, returning success/failure
3. **Application** (`src/application/scheduler.zig:96-130`): Ensure `append_to_logfile()` encodes removal entries (unlike GET/QUERY which return early at line 110)
4. **Infrastructure** (`src/infrastructure/tcp_server.zig:212-240`): Add REMOVE and REMOVERULE parsing in `build_instruction()` following the GET pattern (single identifier argument)
5. **Infrastructure** (`src/infrastructure/persistence/encoder.zig:8-11`): Extend `Entry` union with `job_removal` and `rule_removal` variants using type bytes 2 and 3
6. **Infrastructure** (`src/infrastructure/persistence/background.zig:75-101`): Update compression to exclude IDs whose last entry is a removal

Reference implementations:
- **GET command** (read-only, single identifier): `tcp_server.zig:219-222` → `query_handler.zig:131-180` → skips persistence
- **SET command** (mutation, persisted): `tcp_server.zig:224-230` → `query_handler.zig:74-99` → `scheduler.zig:96-130` → `encoder.zig:29-52`

**Sources**: `src/domain/instruction.zig`, `src/application/query_handler.zig`, `src/application/scheduler.zig`, `src/infrastructure/tcp_server.zig`, `src/infrastructure/persistence/encoder.zig`, `src/infrastructure/persistence/background.zig`

**Recommendation**: REMOVE/REMOVERULE are hybrid: they follow GET's parsing pattern (single identifier) but SET's persistence pattern (append to logfile). Implement across all 6 touch points listed above.

---

### Q2: [TYPES] Which types can F003 reuse?

**Finding**:

| Type | File | Action | Details |
|------|------|--------|---------|
| `Instruction` | `src/domain/instruction.zig:4-20` | **EXTEND** | Add `remove: struct { identifier: []const u8 }` and `remove_rule: struct { identifier: []const u8 }` |
| `Job` | `src/domain/job.zig:10-14` | **REUSE** | No changes; removal references only identifier |
| `Rule` | `src/domain/rule.zig:6-17` | **REUSE** | No changes; removal references only identifier |
| `JobStorage` | `src/application/job_storage.zig:7-51` | **EXTEND** | Add `delete(identifier) -> bool` removing from both `jobs` HashMap and `to_execute` ArrayList |
| `RuleStorage` | `src/application/rule_storage.zig:30-32` | **REUSE** | `delete()` already exists, returns `bool` via `self.rules.remove(identifier)` |
| `Entry` (encoder) | `src/infrastructure/persistence/encoder.zig:8-11` | **EXTEND** | Add `job_removal` (type_byte=2) and `rule_removal` (type_byte=3) variants with identifier-only encoding |
| `Logfile` | `src/infrastructure/persistence/logfile.zig:8-14` | **REUSE** | Length-prefixed framing handles removal entries without changes |
| Background compression | `src/infrastructure/persistence/background.zig:52-110` | **EXTEND** | Update decode switch for type bytes 2/3; skip writing removal entries in compressed output |

Key details:
- `JobStorage` has no `delete()` method — must be added. It must remove from both the `jobs` hashmap and scan/remove from the `to_execute` ArrayList
- `RuleStorage.delete()` confirmed working at line 30-32 — no changes needed
- Encoder type bytes 0 (job) and 1 (rule) are used; 2 and 3 are available for removal entries
- Removal entries need only type_byte + u16 length-prefixed identifier (no timestamp, status, or runner data)
- `free_entry_fields()` in encoder will need no-op handling for removal entries (identifier owned by arena)

**Sources**: `src/application/job_storage.zig`, `src/application/rule_storage.zig`, `src/infrastructure/persistence/encoder.zig`, `src/infrastructure/persistence/logfile.zig`

**Recommendation**: Extend 3 types (Instruction, JobStorage, Entry), reuse 4 types unchanged. The critical new code is `JobStorage.delete()` which must handle the `to_execute` queue.

---

### Q3: [TESTS] What test conventions apply?

**Finding**: Tests follow strict conventions across layers:

**Unit tests** (co-located in source files):
- `src/application/rule_storage.zig:84-98`: Existing `delete removes rule` test — direct pattern for REMOVERULE
- `src/application/job_storage.zig:94-178`: Storage tests use GPA allocator with defer deinit; need new delete tests
- `src/application/query_handler.zig:74-237`: Handler tests create Request with `.client`, `.identifier`, `.instruction`, call `handle()`, verify `Response.success` and storage state
- `src/infrastructure/persistence/encoder.zig:218-296`: Byte-level encode/decode tests with `expectEqualSlices`; use timestamp constant `ts_2020_11_15_16_30_00`
- `src/infrastructure/persistence/background.zig:153-207`: Compression tests use `std.testing.tmpDir`, verify last-write-wins deduplication

**Functional tests** (`src/functional_tests.zig`):
- Lines 263-287: GET round-trip pattern (SET → GET → verify response body)
- Lines 289-303: GET nonexistent (verify failure with null body)
- Lines 159-222: Persistence round-trip (encode → frame → parse → decode → load)

**Required F003 tests**:
1. `JobStorage.delete()` — delete existing job (success), delete missing job (failure), verify to_execute cleanup
2. `QueryHandler.handle()` — remove existing job returns success, remove missing returns failure; same for remove_rule
3. Encoder — encode/decode job_removal (type_byte=2), encode/decode rule_removal (type_byte=3)
4. Background compression — SET + REMOVE for same ID → compressed output excludes that ID
5. Functional — SET → REMOVE → GET round-trip (job absent); RULE SET → REMOVERULE → verify rule gone
6. Persistence round-trip — SET → REMOVE → encode → restart → verify absent after replay

**Sources**: `src/functional_tests.zig`, `src/application/query_handler.zig`, `src/application/job_storage.zig`, `src/application/rule_storage.zig`, `src/infrastructure/persistence/encoder.zig`, `src/infrastructure/persistence/background.zig`

**Recommendation**: Follow existing test patterns exactly. Use GPA allocator with defer deinit. Test both success and failure paths. The `rule_storage.zig:84-98` delete test is the canonical pattern for removal testing.

---

### Q4: [HISTORY] What past decisions are relevant?

**Finding**: F001 (GET) and F002 (QUERY) establish the implementation pattern for new protocol commands:

- **Commit style**: `feat(protocol): add GET command to ztick TCP protocol` (F001: `83e2eb9`), `feat(protocol): add QUERY command for prefix job lookup` (F002: `cfdff95`)
- **Branch naming**: `feature/F001-add-get-command-to-ztick-protocol`, `feature/F002-query-command-for-pattern-based-job-look`
- **Files modified per feature**: Both touched `instruction.zig`, `query_handler.zig`, `scheduler.zig`, `tcp_server.zig`, `encoder.zig`, `protocol.md`, `functional_tests.zig`
- **Persistence routing**: GET and QUERY are read-only (skip `append_to_logfile` at `scheduler.zig:110`). REMOVE/REMOVERULE are mutations and must NOT skip persistence
- **Protocol docs**: `docs/reference/protocol.md:221-226` explicitly lists REMOVE, REMOVERULE, LISTRULES as "Unimplemented Commands" — must update
- **RuleStorage.delete()** already exists from initial implementation — spec assumption confirmed

**Sources**: git log (`83e2eb9`, `cfdff95`), `docs/reference/protocol.md`, `src/application/rule_storage.zig`

**Recommendation**: Follow F001/F002 commit style. Expected commit message: `feat(protocol): add REMOVE and REMOVERULE commands to ztick TCP protocol`. Update protocol docs to move REMOVE/REMOVERULE from unimplemented section.

---

### Q5: [CLEANUP] What code should be removed?

**Finding**: No dead code, stale stubs, or TODO/FIXME markers found. The codebase is well-maintained. Cleanup opportunities are organizational improvements to make during F003:

| Opportunity | File | Risk | Action |
|-------------|------|------|--------|
| Type byte magic numbers (0, 1) hardcoded in encode/decode | `encoder.zig:29,52,116` | LOW | Extract named constants (TYPE_JOB=0, TYPE_RULE=1, TYPE_JOB_REMOVAL=2, TYPE_RULE_REMOVAL=3) |
| Stale "Unimplemented Commands" section | `docs/reference/protocol.md:221-226` | LOW | Remove section; add proper REMOVE/REMOVERULE docs |
| Non-exhaustive switches after adding variants | `tcp_server.zig:339-363` (free_instruction_strings), `query_handler.zig:25-71` (handle) | MEDIUM | Add `.remove` and `.remove_rule` cases — compiler will enforce this |
| `build_instruction()` repetition for single-id commands | `tcp_server.zig:212-240` | MEDIUM | Optional: extract helper for GET/REMOVE/REMOVERULE pattern |

**Sources**: `src/infrastructure/persistence/encoder.zig`, `docs/reference/protocol.md`, `src/infrastructure/tcp_server.zig`, `src/application/query_handler.zig`

**Recommendation**: Named constants for type bytes is the highest-value cleanup. The switch exhaustiveness issues will be caught by the compiler. The `build_instruction` helper extraction is optional — evaluate during implementation whether the duplication warrants it.

---

## Best Practices

| Pattern | Application in F003 |
|---------|----------------------------|
| Hexagonal 4-layer architecture | Changes span domain (instruction variant), application (handler + storage), infrastructure (TCP parsing + persistence), with barrel imports |
| Tagged union exhaustive switches | Adding `.remove` and `.remove_rule` to `Instruction` will trigger compiler errors on all incomplete switches — use this as a checklist |
| Append-only persistence with replay | Removal entries get new type bytes (2, 3) in the logfile; replay on startup deletes from storage |
| Last-write-wins compression | Background compactor already deduplicates by ID; extend to skip IDs whose last entry is a removal |
| Symmetric storage APIs | `RuleStorage.delete()` exists; create matching `JobStorage.delete()` with same signature |
| Co-located unit tests | Add tests in each modified source file following existing patterns |
| GPA allocator + defer deinit | All tests use `std.heap.GeneralPurposeAllocator` with deferred cleanup |

## Dependencies

| Package | Version | Purpose | Status | Action |
|---------|---------|---------|--------|--------|
| Zig stdlib | 0.14.x | All functionality | installed | none |

No external dependencies. Zero-dependency project per ADR-002.

## References

| File | Relevance |
|------|-----------|
| `src/domain/instruction.zig` | Instruction tagged union — add remove/remove_rule variants |
| `src/application/query_handler.zig` | Handler dispatch — add removal cases calling storage.delete() |
| `src/application/job_storage.zig` | Job storage — add delete() method (removes from jobs + to_execute) |
| `src/application/rule_storage.zig` | Rule storage — existing delete() method to reuse |
| `src/application/scheduler.zig` | Scheduler — route removal through append_to_logfile, handle in load() |
| `src/infrastructure/tcp_server.zig` | TCP server — parse REMOVE/REMOVERULE, free instruction strings, write responses |
| `src/infrastructure/persistence/encoder.zig` | Encoder — add type bytes 2/3, encode/decode removal entries |
| `src/infrastructure/persistence/background.zig` | Compressor — exclude removed IDs from compressed output |
| `src/infrastructure/persistence/logfile.zig` | Logfile framing — reuse unchanged |
| `src/functional_tests.zig` | Integration tests — add SET→REMOVE→GET and persistence round-trip tests |
| `docs/reference/protocol.md` | Protocol docs — move REMOVE/REMOVERULE from unimplemented to documented |
