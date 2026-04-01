# Implementation Plan: F004

## Summary

Add a `LISTRULES` protocol command that iterates all rules in `RuleStorage` and returns them as a multi-line response, mirroring the existing `QUERY` command pattern. This is a read-only command requiring no persistence writes, touching 4 files across 3 hexagonal layers plus functional tests.

## Constitution Compliance

Constitution: Derived from CLAUDE.md

| Principle | Status | Notes |
|-----------|--------|-------|
| Hexagonal layering (domain → application → infrastructure) | COMPLIANT | Changes follow domain/instruction.zig → application/query_handler.zig + scheduler.zig → infrastructure/tcp_server.zig |
| Tagged unions for protocol types | COMPLIANT | New `.list_rules` variant added to `Instruction` union(enum) |
| Exhaustive switch enforcement | COMPLIANT | Compiler catches every unhandled `.list_rules` arm across all switches |
| Import through barrel exports only | COMPLIANT | All imports use domain.zig / application.zig barrels |
| Co-located unit tests | COMPLIANT | Tests added in-file next to implementation |
| Zero external dependencies | COMPLIANT | Stdlib only |
| snake_case naming | COMPLIANT | `list_rules` variant, matching `rule_set` / `remove_rule` convention |

## Technical Context

| Field | Value |
|-------|-------|
| Language | Zig 0.14.x |
| Framework | None (stdlib only) |
| Architecture | Hexagonal (domain, application, infrastructure, interfaces) |
| Key patterns | Tagged union dispatch, exhaustive switch propagation, multi-line body as single `[]const u8` with `\n` separators, cross-layer ownership transfer (handler allocates, TCP server frees) |

## Assumptions & Resolutions

| # | Ambiguity | Resolution | Evidence |
|---|-----------|------------|----------|
| A1 | Should `LISTRULES` require any arguments? | No arguments required — empty struct payload like `.get` but without identifier | Spec FR-001: parse `<request_id> LISTRULES\n`; no arguments defined |
| A2 | How to handle `LISTRULES` with trailing args (e.g., `r1 LISTRULES foo`)? | Silently ignore extra args — parse as `list_rules` regardless of trailing tokens | Spec edge case explicitly states "ignores extra arguments"; matches `QUERY` parsing at `tcp_server.zig:230` which only checks `args[0]` |
| A3 | Should `write_response` use a new match arm or reuse `.query` formatting? | Add `.list_rules` to the `.query` match arm as a combined case | `tcp_server.zig:399-419`: `.query` already implements the exact multi-line format needed; LISTRULES output is structurally identical |
| A4 | What format for runner args in output lines? | Shell: `shell <command>`, AMQP: `amqp <dsn> <exchange> <routing_key>` | Spec FR-005 defines this explicitly; matches `RULE SET` input format for round-trip consistency |
| A5 | Memory ownership of `list_rules` instruction | No owned strings — empty struct, `free_instruction_strings` is a no-op | Follows `.get` pattern at `tcp_server.zig:383-385` but without even an identifier to free |

## Approach Comparison

| Criteria | Approach A: Mirror QUERY pattern | Approach B: Shared multi-line helper |
|----------|--------------------------------|-------------------------------------|
| Description | Add `.list_rules` arm to every existing switch, following QUERY exactly | Extract multi-line response logic into shared function, then add LISTRULES |
| Files touched | 4 source + 1 test | 4 source + 1 test + refactor `write_response` |
| New abstractions | 0 | 1 (shared multi-line formatter) |
| Risk level | Low | Med (refactoring existing working code) |
| Reversibility | Easy | Hard (touches QUERY behavior) |

**Selected: Approach A**
**Rationale:** With only 2 multi-line commands (QUERY and LISTRULES), extracting a shared helper is premature. The research explicitly recommends against refactoring `write_response` at this command count (research.md Q5). The QUERY pattern is proven and the compiler's exhaustive switch checking ensures completeness.
**Trade-off accepted:** Minor duplication in `write_response` between `.query` and `.list_rules` arms (both do multi-line splitting). Acceptable at 2 commands; revisit if a third multi-line command is added.

## Key Decisions

| Decision | Rationale | Alternative rejected |
|----------|-----------|---------------------|
| `.list_rules` variant has empty struct `struct {}` | No payload needed — command takes no arguments, reads all rules | Using `void` — Zig tagged unions require struct payloads for consistent destructuring |
| Combine `.list_rules` with `.query` in `write_response` | Both use identical multi-line format: body lines prefixed with request_id, terminated by OK | Separate match arm — would duplicate 15 lines of identical formatting code |
| Add `LISTRULES` to error handling block in `handle_connection` | When `build_instruction` returns null for recognized commands, an ERROR response is sent | Not adding — but spec says extra args are ignored so LISTRULES always succeeds; still add for consistency with other commands |
| Runner formatting via switch on `rule.runner` | Shell and AMQP have different field counts requiring distinct format strings | Single format string — impossible due to different field structures |
| Iterate `rules.valueIterator()` not `rules.iterator()` | Only values (Rule structs) needed; keys are redundant with `rule.identifier` | `rules.iterator()` — unnecessary key access |

## Components

```json
[
  {
    "name": "list_rules_instruction",
    "project": "",
    "layer": "domain",
    "description": "Add .list_rules variant to Instruction tagged union with empty struct payload",
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
    "name": "list_rules_handler",
    "project": "",
    "layer": "application",
    "description": "Add .list_rules arm to QueryHandler.handle() that iterates rule_storage.rules.valueIterator() and formats each rule as '<id> <pattern> <runner_type> <runner_args>\\n' into an ArrayListUnmanaged body buffer. Add .list_rules to scheduler's append_to_logfile read-only skip group.",
    "files": ["src/application/query_handler.zig", "src/application/scheduler.zig"],
    "tests": ["src/application/query_handler.zig", "src/application/scheduler.zig"],
    "dependencies": ["list_rules_instruction"],
    "user_story": "US1, US2, US3",
    "verification": {
      "test_command": "zig build test-application --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "list_rules_protocol",
    "project": "",
    "layer": "infrastructure",
    "description": "Wire LISTRULES through tcp_server.zig: parse command in build_instruction(), add no-op to free_instruction_strings(), extend write_response() to handle .list_rules with multi-line formatting, add LISTRULES to error handling block for recognized commands.",
    "files": ["src/infrastructure/tcp_server.zig"],
    "tests": ["src/infrastructure/tcp_server.zig"],
    "dependencies": ["list_rules_instruction"],
    "user_story": "US1, US2",
    "verification": {
      "test_command": "zig build test-infrastructure --summary all 2>&1 | tail -20",
      "expected_output": "PASS",
      "build_command": "zig build --summary all"
    }
  },
  {
    "name": "list_rules_functional_tests",
    "project": "",
    "layer": "infrastructure",
    "description": "End-to-end functional tests: RULE SET multiple rules then LISTRULES verifies all rules in response, LISTRULES with no rules returns success with null body, LISTRULES with AMQP runner verifies all AMQP fields, LISTRULES does not persist to logfile.",
    "files": ["src/functional_tests.zig"],
    "tests": ["src/functional_tests.zig"],
    "dependencies": ["list_rules_handler", "list_rules_protocol"],
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

**instruction.zig** (co-located):
- `test "list_rules instruction has correct active tag"` — construct `.list_rules` variant, verify tag

**query_handler.zig** (co-located):
- `test "handle list_rules instruction returns success with rules in body"` — set 2 shell rules, send list_rules, verify body contains both rule identifiers/patterns/runners
- `test "handle list_rules instruction returns success with null body when no rules exist"` — empty storage, verify success=true, body=null
- `test "handle list_rules instruction includes amqp runner fields in body"` — set AMQP rule, verify body contains dsn/exchange/routing_key

**scheduler.zig** (co-located):
- `test "handle_query with list_rules instruction does not persist to logfile"` — follows existing no-persist test pattern at scheduler.zig:397-433

**tcp_server.zig** (co-located):
- `test "build_instruction parses LISTRULES command"` — verify returns `.list_rules` instruction
- `test "build_instruction parses LISTRULES command ignoring trailing args"` — `LISTRULES foo` still returns `.list_rules`
- `test "write_response formats list_rules multi-line body with request_id prefix"` — socketpair test matching write_response test at tcp_server.zig:553-583
- `test "write_response formats list_rules empty result as OK only"` — body=null case

### Functional Tests

**functional_tests.zig**:
- `test "RULE SET then LISTRULES returns all rules"` — set 2 shell rules via handle_query, send list_rules, verify both appear in body with correct format
- `test "LISTRULES with no rules returns success with null body"` — empty scheduler, verify success + null body
- `test "LISTRULES with AMQP rule includes all runner fields"` — set AMQP rule, verify dsn/exchange/routing_key in body

## Risks

| Risk | Probability | Impact | Mitigation | Owner |
|------|-------------|--------|------------|-------|
| Hash map iteration order makes test assertions fragile | Med | P1 | Use `std.mem.indexOf` for content verification (not exact string match); count lines separately. Follows existing QUERY test pattern at functional_tests.zig:354-356 | Developer |
| Missing a switch arm causes compile error blocking all tests | Low | P0 | Zig's exhaustive switch checking is the safety net — add `.list_rules` to Instruction first, then fix all compile errors before running tests | Developer |
| Runner format string mismatch between LISTRULES output and RULE SET input | Low | P1 | Test AMQP rule specifically; verify format matches FR-005 spec definition | Developer |

## Cleanup Opportunities

| Target | Reason | Action |
|--------|--------|--------|
| None | Feature is purely additive — no code replaced or deprecated | N/A |

**Note:** If a third multi-line response command is added in the future, `write_response()` should be refactored to extract the multi-line formatting into a shared helper. At 2 commands this is premature.
