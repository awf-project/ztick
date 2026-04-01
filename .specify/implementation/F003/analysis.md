ARTIFACT_ANALYSIS

## Findings

| ID | Category | Severity | Location | Summary | Recommendation |
|----|----------|----------|----------|---------|----------------|
| F1 | Ordering | HIGH | tasks:dependencies T005→T006 | `scheduler.append_to_logfile()` (T006) depends on QueryHandler (T005) but should depend on Entry types (T004) and Instruction variants (T001); append_to_logfile converts Instructions to Entries and persists them — QueryHandler state is irrelevant to that path | Redirect T006 dependency to T004; T005 and T006 can run in parallel after T002/T004 |
| D1 | Coverage Gap | HIGH | spec:FR-009 | FR-009 ("System MUST respect fsync_on_persist for removal entries") has no associated task; none of T004, T006, or T007 mention fsync_on_persist | Add acceptance criterion to T006: "fsync_on_persist=true causes fsync call on logfile fd, matching SET behavior" |
| C1 | Underspecification | HIGH | tasks:T010 | Acceptance criteria: "Round-trip test confirms removed rule no longer matches jobs" — no mechanism defined for observing rule absence; REMOVERULE has no query equivalent (QUERY is for jobs, not rules); the test cannot confirm rule absence without scheduling a job and observing tick behavior | Specify: either verify via scheduler tick producing no execution for a matching job, or accept that OK response + reload absence (T011-style) is sufficient |
| G1 | Logical | MEDIUM | tasks:dependencies T003→T005 | TCP parsing task (infrastructure layer) listed as prerequisite for QueryHandler task (application layer); violates hexagonal direction — application must not depend on infrastructure; this is a task-ordering artifact but risks confusing implementers about actual code dependencies | Document that T003→T005 is a testing convenience (run full stack after parser exists), not a code dependency; QueryHandler depends only on T001+T002 |
| C2 | Underspecification | MEDIUM | tasks:T006 | FR-006 requires persistence before confirming OK, but T006 acceptance ("scheduler.append_to_logfile() produces correct Entry for persistence") does not specify ordering relative to QueryHandler response path; crash between persist and respond is an unaddressed failure mode | Add explicit acceptance criterion: "co-located test confirms Entry is written before handle() return value is used to build response" |
| F2 | Ordering | MEDIUM | tasks:dependencies T012 | T012 (docs) depends on T009+T010 but not T011; SC-003 ("after restart, removed entries absent") is documented in the spec and requires T011 evidence | Add T011 as T012 dependency |
| D2 | Coverage Gap | MEDIUM | spec:NFR-001 | "REMOVE/REMOVERULE latency MUST be comparable to SET (sub-millisecond excluding fsync)" — no task measures or asserts latency; the qualifier "comparable" is not quantified | Either add a benchmark task or downgrade NFR-001 to an operational note with no test obligation; document the decision |
| D3 | Coverage Gap | MEDIUM | spec:NFR-003 | NFR-003 ("no new allocations beyond identifier string copy; memory MUST not grow with removal count") has no associated task or test | Add memory assertion to T002/T005 unit tests: verify allocator sees exactly one alloc for identifier per delete call |
| D4 | Duplication | MEDIUM | tasks:T003+T013 | T003 acceptance already includes "handle_connection sends ERROR for malformed commands"; T013 exists to "verify before starting" whether T003 already satisfied it; if T003 fully implements the unified conditional, T013 has no work | Collapse T013 into T003 acceptance criteria; remove T013 as a standalone task to avoid confusion |
| B1 | Ambiguity | MEDIUM | spec:Assumptions | "e.g., 2 for job removal, 3 for rule removal" — "e.g." implies these are illustrative, not normative; plan commits firmly to bytes 2 and 3 without flagging the spec's hedging | Change spec assumption to "2 for job_removal, 3 for rule_removal" (drop "e.g.") or add a resolution note in plan linking to the spec assumption |
| E1 | Terminology | LOW | spec:Key Entities | "PersistenceEntry" appears only in the Key Entities table; every other reference in spec, plan, and tasks uses "Entry"; no type named PersistenceEntry exists in the codebase | Rename to "Entry" in Key Entities table for consistency |
| B2 | Ambiguity | LOW | spec:NFR-002 | NFR-002 states removal entries "MUST use the existing length-prefixed framing format with no new framing scheme" but has no associated test; T004 implicitly covers this via encode/decode round-trip but doesn't assert the exact frame layout | Add one assertion to T004 encoder test: verify encoded bytes start with 4-byte big-endian length prefix matching actual payload length |
| D5 | Coverage Gap | LOW | spec:NFR-002 | No task explicitly tests that removal entries do not introduce a new framing scheme (beyond the round-trip test in T004) | Merge with B2 recommendation above |

## Coverage Map

| Requirement | Has Task? | Task IDs | Notes |
|-------------|-----------|----------|-------|
| FR-001 | Yes | T003 | |
| FR-002 | Yes | T003 | |
| FR-003 | Yes | T002, T005 | Hashmap + to_execute list both addressed |
| FR-004 | Yes | T005 | |
| FR-005 | Yes | T005 | OK/ERROR return from handle() |
| FR-006 | Partial | T006 | Persist-before-respond ordering implicit; not asserted in acceptance criteria |
| FR-007 | Yes | T007 | |
| FR-008 | Yes | T008 | |
| FR-009 | No | — | Gap: fsync_on_persist behavior for removal entries unassigned |
| NFR-001 | No | — | No latency measurement or benchmark task |
| NFR-002 | Partial | T004 | Round-trip test covers encode/decode; framing format compliance not explicitly asserted |
| NFR-003 | No | — | No allocation growth test |

## Metrics

- Total Requirements: 12 (FR-001–FR-009 + NFR-001–NFR-003)
- Total Tasks: 13
- Coverage: 75% (9/12 requirements with ≥1 task; FR-009, NFR-001, NFR-003 uncovered)
- Critical Issues: 0
- High Issues: 3 (F1, D1, C1)
- Ambiguities: 2 (B1, B2)
- Gaps: 4 (FR-009, NFR-001, NFR-002 partial, NFR-003)

## Verdict

CRITICAL_COUNT: 0
HIGH_COUNT: 3
COVERAGE_PERCENT: 75
RECOMMENDATION: REVIEW_NEEDED
