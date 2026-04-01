ARTIFACT_ANALYSIS

## Findings

| ID | Category | Severity | Location | Summary | Recommendation |
|----|----------|----------|----------|---------|----------------|
| F01 | Underspecification | CRITICAL | plan:connection_abstraction, tasks:T003 | `TlsStream` type referenced in `Connection = union(enum) { plain: std.net.Stream, tls: TlsStream }` but never defined anywhere. T002 creates `TlsContext` (the server SSL_CTX) but no component defines the per-connection TLS stream wrapper type that `Connection.tls` would hold | Define `TlsStream` struct (wrapping `SSL*` pointer + fd) in T002 or as a dedicated component; T003 depends on it existing |
| F02 | Coverage Gap | CRITICAL | spec:NFR-002, tasks:* | "Certificate file contents and private key material MUST NOT appear in log output or error messages" has zero task and zero test coverage | Add acceptance criterion to T002: assert error messages from failed PEM loads do not include file content; add to T005 startup error path |
| F03 | Underspecification | CRITICAL | plan:§Key Decisions, tasks:T006 | "Conditionally link libssl when TLS source files are present" — mechanism never defined. If `tls_context.zig` is committed (it always will be), the condition is always true, making conditional linking meaningless. No build flag (`-Dtls=true/false`) is defined anywhere | Define a `-Dtls` build option in build.zig; document default value; clarify that "plaintext-only builds" requires explicitly passing `-Dtls=false` |
| F04 | Coverage Gap | HIGH | spec:FR-007 edge case, tasks:T002 | Spec explicitly states "private key does not match the certificate → fail at startup with a clear error" but T002's acceptance criteria only cover: valid pair, nonexistent cert path, invalid PEM. Key/cert mismatch is a distinct OpenSSL error (SSL_CTX_check_private_key) not in scope of "invalid PEM" | Add acceptance criterion to T002: mismatched cert/key pair returns distinct error |
| F05 | Coverage Gap | HIGH | spec:NFR-001, tasks:* | "TLS handshake latency MUST add less than 50ms on localhost" — no task measures or validates this NFR. It is a MUST-level requirement with no test coverage | Add a timing assertion to T008 or note as explicitly out-of-scope with rationale |
| F06 | Ambiguity | HIGH | tasks:T014 | `[R]` tag used in T014 but the Execution Notes legend only defines `[M]`, `[L]`, `[S]`, `[P]`, `[E]`. Meaning of `[R]` is undefined — likely "Refactor" but unverified | Add `[R]` to the tag legend with its meaning |
| F07 | Underspecification | HIGH | tasks:T008 | "Connect via TLS client" in functional test is unspecified. Given `std.crypto.tls` is client-only in Zig stdlib (confirmed in plan assumptions), the test client implementation is non-trivial. Options (stdlib TLS client, spawn `openssl s_client` subprocess, C interop client) have different complexity/reliability tradeoffs | Specify the TLS client approach for functional tests; subprocess via `openssl s_client` is the lowest-risk option given existing process-based CLI test patterns |
| F08 | Coverage Gap | HIGH | plan:§Risks "Add apt-get install libssl-dev to CI", tasks:* | Plan explicitly identifies updating CI to install `libssl-dev` as required but no task covers it. Without this, CI will fail on the first build | Add a task (or extend T006) to update `.github/workflows/*.yml` with libssl-dev installation |
| F09 | Ambiguity | MEDIUM | spec:FR-008 | `[NEEDS CLARIFICATION: union type vs vtable — depends on Zig stdlib TLS API shape]` marker remains in spec. Plan resolves this (tagged union selected) but the spec still presents it as open. Creates confusion about whether spec is authoritative | Remove the NEEDS CLARIFICATION marker from spec now that resolution is documented in plan |
| F10 | Ambiguity | MEDIUM | spec:NFR-004 | `[NEEDS CLARIFICATION: std.crypto.tls.Server availability in Zig 0.14 needs verification]` marker remains in spec. Plan confirms it is client-only (server absent) | Remove the NEEDS CLARIFICATION marker; update text to state stdlib server TLS is confirmed absent |
| F11 | Ambiguity | MEDIUM | tasks:T007 | "Add `test/fixtures/tls/` to `.gitignore` if certs should not be committed, **or** commit test-only self-signed certs" — the decision is explicitly left open. If certs are not committed, CI needs a generation step (not in any task). If committed, `.gitignore` addition is wrong | Decide and document: self-signed test certs should be committed (they contain no secrets); remove the conditional |
| F12 | Coverage Gap | MEDIUM | spec:FR-006, tasks:T008 | FR-006 requires all 6 protocol commands (SET, REMOVE, QUERY, RULE SET, REMOVERULE, LISTRULES) work identically over TLS. T008 only tests SET | Extend T008 acceptance criteria to cover at least one additional command, or add a note that FR-006 is validated by the Connection abstraction making protocol handling transport-agnostic |
| F13 | Ambiguity | MEDIUM | spec:US5 | Acceptance scenario: "operator can generate a self-signed cert and start ztick with TLS in under 5 minutes" — wall-clock time is untestable and subjective | Replace with a verifiable criterion: "following the documented steps produces a running TLS-enabled instance" |
| F14 | Ordering | LOW | tasks:dependency graph | T014 depends on T013 (README update) per the graph, but T014's work (cleanup duplicate test Context structs, build.zig.zon comment) is logically independent of README content. This chains a code-cleanup task behind documentation with no justification | Remove T014 → T013 dependency; T014 can run in parallel with T012/T013 |
| F15 | Coverage Gap | LOW | spec:edge cases, tasks:T002 | Edge case "file permissions prevent reading the key file" not in T002's acceptance criteria (distinct from nonexistent path or invalid PEM) | Add permission-denied error as an acceptance criterion in T002 |

## Coverage Map

| Requirement | Has Task? | Task IDs | Notes |
|-------------|-----------|----------|-------|
| FR-001 | Yes | T002, T003, T005, T008 | |
| FR-002 | Yes | T001, T003, T005, T009 | |
| FR-003 | Yes | T001, T010 | |
| FR-004 | Partial | T002 | No test asserts "once at startup, not per-connection" explicitly |
| FR-005 | Yes | T011 | |
| FR-006 | Partial | T008 | T008 only validates SET; 5 remaining commands untested over TLS |
| FR-007 | Partial | T002 | Key/cert mismatch and permission-denied cases missing from T002 acceptance criteria |
| FR-008 | Yes | T003 | |
| NFR-001 | No | — | MUST-level latency requirement with zero test coverage |
| NFR-002 | No | — | MUST-level security requirement with zero task or test coverage |
| NFR-003 | Yes | T011 | |
| NFR-004 | Partial | T006 | Conditional linking mechanism undefined; see F03 |

## Metrics

- Total Requirements: 12 (FR-001–FR-008 + NFR-001–NFR-004)
- Total Tasks: 14
- Coverage: 67% of requirements have adequate task coverage (8/12); 83% have at least one task (10/12)
- Critical Issues: 3
- High Issues: 5
- Ambiguities: 5
- Gaps: 6

## Verdict

CRITICAL_COUNT: 3
HIGH_COUNT: 5
COVERAGE_PERCENT: 67
RECOMMENDATION: REVIEW_NEEDED
