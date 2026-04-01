ARTIFACT_ANALYSIS

## Findings

| ID | Category | Severity | Location | Summary | Recommendation |
|----|----------|----------|----------|---------|----------------|
| F1 | Ordering | CRITICAL | tasks:T003, T004 | T004 (fixture files) is listed as dependent on T003 in the Mermaid graph (`T003 --> T004`), but T003's unit tests require the fixture files to exist. Fixtures are a prerequisite for the parser tests, not a product of them. | Reverse the dependency: T004 should be created independently (or before T003). Remove `T003 --> T004` arrow; T004 has no real predecessor. |
| F2 | Coverage | CRITICAL | spec:SC-005, tasks | SC-005 requires "a test asserting equal execution path regardless of secret prefix match length" — this is not a property Zig tests can deterministically verify. Timing behavior is not observable through `std.testing`. The plan resolves this by using `std.crypto.timing_safe.eql` (provably constant-time by construction), but no T002 acceptance criterion reflects a behavioral test that is actually achievable. | Replace SC-005 wording with an achievable assertion: "unit test verifies `std.crypto.timing_safe.eql` is called for comparison" or drop the execution-path framing entirely. |
| F3 | Coverage | HIGH | spec:FR-010, tasks | FR-010 (5-second auth timeout) has no functional test. T007 mentions it in unit acceptance but no T009–T014 entry covers the timeout path end-to-end. | Add T015: functional test — connection that sends no data within 5s is closed by server. Mark as [S] in Phase 4. |
| F4 | Coverage | HIGH | spec:NFR-001 | NFR-001 ("auth handshake MUST complete in under 1ms") has zero associated tasks. | Add benchmark task or explicitly mark as out-of-scope for v1 with a rationale. |
| F5 | Coverage | HIGH | spec:NFR-002 | NFR-002 ("secrets MUST NOT appear in log output") has zero associated tasks. No test verifies log output is clean. | Add assertion in T007 or T002: capture log output during authentication and assert no secret substring appears. |
| F6 | Coverage | HIGH | spec:NFR-005 | NFR-005 ("MUST document that TLS is recommended when using auth") has no task in any phase. | Add T016: documentation task — add TLS-recommendation note to relevant config docs and/or README. |
| F7 | Coverage | HIGH | spec:NFR-003, NFR-004 | NFR-003 (≤1μs namespace check overhead) and NFR-004 (1000 tokens, <100ms startup) have zero associated tasks. | Accept as untested NFRs for v1 (document deferral) or add micro-benchmark tasks. If deferred, state so explicitly in plan. |
| F8 | Ambiguity | HIGH | tasks:T002 | T002 acceptance says "via SHA-256 digest comparison" but this critical security decision is only justified in the plan's Risk section. An implementer reading only T002 might implement SHA-256 hashing without understanding *why*, missing the implication that `TokenStore.authenticate()` never compares raw secrets at all. | Add "Why" sentence to T002 acceptance: "SHA-256 both stored and incoming secrets before `timing_safe.eql` because `eql` requires fixed-length arrays; raw secrets must never be compared directly." |
| F9 | Coverage | MEDIUM | spec edge-cases, tasks | Edge case "client sends `AUTH 
` with no token" is enumerated in spec but no task or test covers it. | Add assertion in T007 unit test: empty-token AUTH returns ERROR and closes connection. |
| F10 | Coverage | MEDIUM | spec edge-cases, tasks | Edge case "second AUTH after successful authentication" is in spec but has no functional test. T007 unit acceptance mentions it but functional coverage is absent. | Add scenario to T009 or a new functional test: after valid AUTH, second AUTH returns ERROR. |
| F11 | Ordering | MEDIUM | tasks:Phase 2 | T004 is placed in Phase 2 with marker [P] but the dependency graph `T003 --> T004` contradicts the parallel marker. The [P] annotation is correct; the Mermaid edge is wrong. | Remove `T003 --> T004` from the dependency graph. T004 can execute in parallel with T001 or T002. |
| F12 | Underspecification | MEDIUM | spec:Assumptions, tasks | The spec assumption "namespace prefixes always end with a period" is enforced only informally. No task validates this at auth file parse time, and no test covers a namespace value like `deploy` (without trailing period). | Add parse-time validation to T003 acceptance: "namespace values must end with `.` or equal `*`; missing trailing period returns error." |
| F13 | Underspecification | MEDIUM | tasks:T007 | T007 acceptance says "connection closure on auth failure" and "5-second read timeout via SO_RCVTIMEO" but does not specify what the server sends (if anything) before closing on timeout. FR-010 says "closes the connection" with no ERROR specified for timeout path. | Clarify T007: on timeout, server closes connection without sending ERROR (distinguish from invalid-token path which sends ERROR then closes). |
| F14 | Terminology | MEDIUM | spec:FR-009, tasks:T002 vs T003 | FR-009 validation (duplicate secrets, empty namespaces) is split between T002 ("rejects at init") and T003 ("rejects at parse time"). Both tasks claim ownership of FR-009 with different triggering points and different error surfaces, which may produce duplicate validation or inconsistent error messages. | Clarify ownership: T003 (parser) rejects structural violations; T002 (TokenStore init) rejects semantic violations like duplicates. Document in T002/T003 acceptance which errors belong where. |
| F15 | Ambiguity | MEDIUM | spec:FR-006, plan:A3 | Plan resolution A3 says QUERY filtering is done "by re-querying with intersected prefix (namespace + query pattern)" but this only works when the query pattern is a prefix (e.g. `deploy.*`). If a client with `deploy.` namespace sends `QUERY backup.*`, a prefix intersection of `deploy.` and `backup.` is empty — correct behavior, but not specified in T008 acceptance. | Add to T008 acceptance: "when client namespace and QUERY pattern have no common prefix, return empty result set." |
| F16 | Ambiguity | LOW | plan:§Key Decisions | "Auth file path resolution relative to config file vs CWD" is listed as a risk resolved by "relative to CWD, same as logfile_path." No task acceptance criterion or test verifies this path-resolution behavior. | Add one-line assertion in T003 or T005 tests: relative path `auth_file = "relative/path.toml"` resolves from CWD. |
| F17 | Ambiguity | LOW | spec:NFR-001, spec:SC-001 | NFR-001 says AUTH completes in "under 1ms" but SC-001 says connections without valid AUTH are rejected "within 100ms." These are different metrics for different paths (valid vs invalid) but the gap (1ms vs 100ms) is unexplained and may confuse implementers. | Add clarifying note: 100ms rejection window in SC-001 includes network round-trip and is the user-visible bound; the 1ms NFR-001 is for server-side processing only. |

## Coverage Map

| Requirement | Has Task? | Task IDs | Notes |
|-------------|-----------|----------|-------|
| FR-001 | Yes | T007 | Unit + functional (T009) |
| FR-002 | Yes | T007, T009, T010 | |
| FR-003 | Yes | T005, T006, T011 | |
| FR-004 | Yes | T008, T012 | |
| FR-005 | Yes | T008, T013 | |
| FR-006 | Yes | T008, T013 | |
| FR-007 | Yes | T008, T014 | |
| FR-008 | Yes | T002 | SHA-256 approach mitigates array-size constraint |
| FR-009 | Yes | T002, T003 | Ownership split unclear (F14) |
| FR-010 | Partial | T007 | No functional test for timeout path (F3) |
| FR-011 | Yes | T001, T002 | |
| NFR-001 | No | — | Gap: no benchmark or acceptance task (F4) |
| NFR-002 | No | — | Gap: no log-cleanliness test (F5) |
| NFR-003 | No | — | Gap: deferred NFR not explicitly documented |
| NFR-004 | No | — | Gap: deferred NFR not explicitly documented |
| NFR-005 | No | — | Gap: no documentation task (F6) |
| SC-001 | Partial | T007 | No end-to-end timing assertion |
| SC-002 | Yes | T008, T012 | |
| SC-003 | Yes | T011 | |
| SC-004 | Yes | T009–T014 | Auth timeout scenario absent |
| SC-005 | Partial | T002 | Untestable as written (F2) |

## Metrics

- Total Requirements: 21 (FR-001–FR-011, NFR-001–NFR-005, SC-001–SC-005)
- Total Tasks: 14
- Coverage: 62% (13/21 requirements have ≥1 task; 5 NFRs and SC-005 gap)
- Critical Issues: 2
- High Issues: 5
- Ambiguities: 4
- Gaps: 6

## Verdict

CRITICAL_COUNT: 2
HIGH_COUNT: 5
COVERAGE_PERCENT: 62
RECOMMENDATION: REVIEW_NEEDED
