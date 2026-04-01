# Implementation Plan: F003

## Summary

Add REMOVE and REMOVERULE commands to the ztick TCP protocol, enabling deletion of scheduled jobs and execution rules. Implementation follows the hybrid pattern: GET-style parsing (single identifier argument) with SET-style persistence (append to logfile), touching all four hexagonal layers plus the persistence encoder and background compressor.

## Constitution Compliance

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal Architecture | COMPLIANT | Changes follow domain -> application -> infrastructure ordering; domain types have zero deps, application depends only on domain, infrastructure implements adapters |
| TDD Methodology | COMPLIANT | Co-located unit tests in each modified source file; functional tests in functional_tests.zig; covers happy path + error paths per component |
| Zig Idioms | COMPLIANT | Error unions for fallible operations, explicit allocator passing, errdefer for cleanup, no hidden allocations |
| Minimal Abstraction | COMPLIANT | No new abstractions; extends existing tagged unions (Instruction, Entry) with new variants; reuses existing storage/handler patterns |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.14.x |
| Framework | None (stdlib only, zero deps per ADR-002) |
| Architecture | Hexagonal 4-layer: domain, application, infrastructure, interfaces |
| Key patterns | Tagged unions for instruction/entry dispatch, exhaustive switches, append-only persistence with length-prefixed framing, last-write-wins compression |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | What type bytes to use for removal entries | Use 2 for job_removal, 3 for rule_removal | `encoder.zig:29` uses 0 for job, `encoder.zig:52` uses 1 for rule; sequential allocation |
| A2 | How JobStorage.delete() handles to_execute queue | Linear scan and remove, matching the SET pattern | `job_storage.zig:32-39` already scans to_execute linearly during set(); same approach for delete |
| A3 | Whether removal entries need data beyond identifier | Identifier-only; type_byte + u16-prefixed identifier | `encoder.zig:24-39` shows job entries carry full data; removals only need to identify what to delete |
| A4 | How scheduler.load() handles removal entries during replay | Call storage.delete() when decoding removal entries | `scheduler.zig:77-80` switches on entry type and calls storage methods; add .job_removal/.rule_removal cases |
| A5 | Whether compressor should write removal entries for removed IDs | No; skip entirely when last entry is a removal | `background.zig:94-96` already skips duplicate entries; removal as last entry means the ID should not appear at all |
| A6 | How handle_connection sends ERROR for malformed REMOVE/REMOVERULE | Same pattern as QUERY: check command name, send ERROR when build_instruction returns null | `tcp_server.zig:189-198` shows the QUERY malformed-command ERROR pattern; extend to REMOVE/REMOVERULE |

## Approach Comparison

| Criteria | Approach A: Extend existing patterns | Approach B: Refactor with type constants first |
|----------|--------------------------------------|-----------------------------------------------|
| Description | Add variants directly to Instruction, Entry, and handlers following current code style | Extract type byte constants, then add removal variants |
| Files touched | 8 | 8 |
| New abstractions | 0 | 1 (type byte constants enum/namespace) |
| Risk level | Low | Low |
| Reversibility | Easy | Easy |

**Selected: Approach A**
**Rationale:** The codebase uses literal type bytes (0, 1) consistently. Adding 2 and 3 follows the same pattern with zero refactoring risk. The compiler's exhaustive switch checking ensures all dispatch points are updated. Extracting constants is a cleanup opportunity but not required for correctness.
**Trade-off accepted:** Magic numbers remain (0, 1, 2, 3) in encoder; acceptable given the small fixed set and inline comments.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| Removal entries encode identifier-only (no timestamp/status/runner) | Removal semantics need only the ID; smaller logfile entries, simpler encoding | Full entity snapshot in removal entry (wasteful, no consumer) |
| JobStorage.delete() returns bool (matching RuleStorage) | Symmetric API; bool return directly maps to OK/ERROR response | Returning the deleted Job (spec says no response body for REMOVE) |
| Persist before responding OK | FR-006 requires persistence before confirmation; crash safety | Respond first, persist async (risks data loss) |
| Extend handle_connection ERROR pattern for REMOVE/REMOVERULE | Consistent with existing QUERY malformed-command handling | Silent ignore (spec requires ERROR response) |

## Components

```json
[
  {
    "name": "domain_instruction_variants",
    "project": "",
    "layer": "domain",
    "description": "Add .remove and .remove_rule variants to the Instruction tagged union, each with a single identifier field",
    "files": ["src/domain/instruction.zig"],
    "tests": ["src/domain/instruction.zig"],
    "dependencies": [],
    "user_story": "US1, US2",
    "verification": {
      "test_command": "zig build test-domain --summary all",
      "expected_output": "Build Summary: 4/4 passed",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "job_storage_delete",
    "project": "",
    "layer": "application",
    "description": "Add delete(identifier) -> bool method to JobStorage that removes from both jobs hashmap and to_execute list",
    "files": ["src/application/job_storage.zig"],
    "tests": ["src/application/job_storage.zig"],
    "dependencies": ["domain_instruction_variants"],
    "user_story": "US1",
    "verification": {
      "test_command": "zig build test-application --summary all",
      "expected_output": "passed",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "query_handler_removal",
    "project": "",
    "layer": "application",
    "description": "Add .remove and .remove_rule cases to QueryHandler.handle() that call storage.delete() and return success/failure. Update scheduler.append_to_logfile() to encode removal entries. Update scheduler.load() to replay removal entries via storage.delete().",
    "files": [
      "src/application/query_handler.zig",
      "src/application/scheduler.zig"
    ],
    "tests": [
      "src/application/query_handler.zig",
      "src/application/scheduler.zig"
    ],
    "dependencies": ["job_storage_delete"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-application --summary all",
      "expected_output": "passed",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "persistence_removal_encoding",
    "project": "",
    "layer": "infrastructure",
    "description": "Extend Entry union with job_removal and rule_removal variants (type bytes 2 and 3). Implement encode/decode for identifier-only removal entries. Add free_entry_fields handling. Update background compressor to exclude IDs whose last entry is a removal.",
    "files": [
      "src/infrastructure/persistence/encoder.zig",
      "src/infrastructure/persistence/background.zig"
    ],
    "tests": [
      "src/infrastructure/persistence/encoder.zig",
      "src/infrastructure/persistence/background.zig"
    ],
    "dependencies": ["domain_instruction_variants"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-infrastructure --summary all",
      "expected_output": "passed",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "tcp_server_parsing",
    "project": "",
    "layer": "infrastructure",
    "description": "Add REMOVE and REMOVERULE parsing to build_instruction(). Add .remove/.remove_rule cases to free_instruction_strings(). Extend handle_connection ERROR handling for malformed REMOVE/REMOVERULE commands.",
    "files": ["src/infrastructure/tcp_server.zig"],
    "tests": ["src/infrastructure/tcp_server.zig"],
    "dependencies": ["domain_instruction_variants"],
    "user_story": "US1, US2",
    "verification": {
      "test_command": "zig build test-infrastructure --summary all",
      "expected_output": "passed",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "functional_tests_and_docs",
    "project": "",
    "layer": "infrastructure",
    "description": "Add functional tests: SET->REMOVE->GET round-trip (job absent), RULE SET->REMOVERULE->verify rule gone, persistence round-trip with removal entries. Update protocol.md to document REMOVE/REMOVERULE and remove them from Unimplemented Commands section.",
    "files": [
      "src/functional_tests.zig",
      "docs/reference/protocol.md"
    ],
    "tests": ["src/functional_tests.zig"],
    "dependencies": ["query_handler_removal", "persistence_removal_encoding", "tcp_server_parsing"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-functional --summary all",
      "expected_output": "passed",
      "build_command": "zig build --summary all"
    }
  }
]
```

## Test Plan

### Unit Tests

| Component | Test | File |
|-----------|------|------|
| domain_instruction_variants | remove instruction stores identifier | instruction.zig |
| domain_instruction_variants | remove_rule instruction stores identifier | instruction.zig |
| job_storage_delete | delete existing job returns true, job absent from get() | job_storage.zig |
| job_storage_delete | delete existing job removes from to_execute list | job_storage.zig |
| job_storage_delete | delete missing job returns false | job_storage.zig |
| query_handler_removal | handle remove existing job returns success | query_handler.zig |
| query_handler_removal | handle remove missing job returns failure | query_handler.zig |
| query_handler_removal | handle remove_rule existing rule returns success | query_handler.zig |
| query_handler_removal | handle remove_rule missing rule returns failure | query_handler.zig |
| persistence_removal_encoding | encode/decode job_removal round-trip (type byte 2) | encoder.zig |
| persistence_removal_encoding | encode/decode rule_removal round-trip (type byte 3) | encoder.zig |
| persistence_removal_encoding | compress SET+REMOVE same ID produces empty output | background.zig |
| tcp_server_parsing | build_instruction parses REMOVE with identifier | tcp_server.zig |
| tcp_server_parsing | build_instruction returns null for REMOVE without identifier | tcp_server.zig |
| tcp_server_parsing | build_instruction parses REMOVERULE with identifier | tcp_server.zig |
| tcp_server_parsing | build_instruction returns null for REMOVERULE without identifier | tcp_server.zig |
| tcp_server_parsing | free_instruction_strings frees REMOVE identifier without leak | tcp_server.zig |

### Functional Tests

| Test | File |
|------|------|
| SET -> REMOVE -> GET returns failure (job absent) | functional_tests.zig |
| RULE SET -> REMOVERULE -> verify rule gone from pairing | functional_tests.zig |
| SET -> REMOVE -> persist -> reload -> job absent | functional_tests.zig |
| RULE SET -> REMOVERULE -> persist -> reload -> rule absent | functional_tests.zig |

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Exhaustive switch compilation errors cascade across many files | High | P2 | Zig compiler will flag every incomplete switch; use as implementation checklist. Add variants + all switch cases in same component before moving to next. | Developer |
| JobStorage.delete() to_execute scan correctness | Medium | P1 | Follow existing linear scan pattern from set() at job_storage.zig:32-39. Test with job in queue and job not in queue. | Developer |
| Compressor incorrectly writes removal entries instead of skipping | Low | P1 | Explicit test: SET+REMOVE for same ID -> compressed output has zero entries for that ID. Verify parsed.entries.len after compression. | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| `docs/reference/protocol.md:221-226` "Unimplemented Commands" section | REMOVE and REMOVERULE become implemented; only LISTRULES remains | Update section to list only LISTRULES |
| `tcp_server.zig:189-198` QUERY-only ERROR handling | REMOVE/REMOVERULE need same pattern; currently only checks for QUERY | Extend conditional to include REMOVE and REMOVERULE command names |
