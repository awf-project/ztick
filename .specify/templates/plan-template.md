# Implementation Plan: [FEATURE ID] - [FEATURE TITLE]

**Branch**: `[branch-name]` | **Date**: [DATE] | **Spec**: [path to spec]

## Summary

[1-2 sentences: primary requirement from spec + chosen technical approach]

## Technical Context

<!--
  Fill based on project detection and research.
  Mark unknown items as [NEEDS CLARIFICATION] — these block implementation.
-->

| Field | Value |
|-------|-------|
| **Language/Version** | [e.g., Go 1.23, TypeScript 5.7] |
| **Primary Framework** | [e.g., Cobra, Next.js, Symfony] |
| **Storage** | [e.g., PostgreSQL, SQLite, files, N/A] |
| **Testing** | [e.g., go test, vitest, phpunit] |
| **Build** | [e.g., make build, npm run build] |
| **Lint** | [e.g., golangci-lint, eslint] |

## Constitution Check

<!--
  GATE: Must pass before implementation begins.
  For each principle in .specify/memory/constitution.md, assess PASS/FAIL/N/A.
  A single FAIL blocks the plan until resolved.
-->

| Principle | Status | Evidence |
|-----------|--------|----------|
| [Principle 1 Name] | PASS / FAIL / N/A | [1-sentence justification] |
| [Principle 2 Name] | PASS / FAIL / N/A | [1-sentence justification] |
| [Principle 3 Name] | PASS / FAIL / N/A | [1-sentence justification] |

## Architecture Approach

### Affected Components

<!--
  List existing files/modules that will be modified, and new ones to create.
  Use the project's actual directory structure.
-->

| Component | Action | Path | Rationale |
|-----------|--------|------|-----------|
| [Component name] | create / modify | [file path] | [why] |

### Data Model Changes

<!--
  Include only if the feature involves data changes.
  Describe at the domain level: entities, relationships, constraints.
-->

[Data model description or "N/A - no data model changes"]

### API/Interface Changes

<!--
  Include only if the feature adds or modifies public interfaces.
  Describe contracts, not implementation.
-->

[Interface changes or "N/A - no interface changes"]

## Architecture Decisions

<!--
  Significant decisions made during this plan that should be recorded as ADRs.
  Each decision should either reference an existing ADR or propose a new one.

  When to create an ADR:
  - Choosing a library, framework, or tool
  - Defining a data model or API contract
  - Selecting an architecture pattern
  - Making a trade-off that affects future work

  Minor implementation choices (variable names, file organization) don't need ADRs.
-->

### Existing ADRs Referenced

| ADR | Title | Relevance to this plan |
|-----|-------|----------------------|
| [ADR-NNNN](docs/ADR/NNNN-name.md) | [Title] | [How it constrains or informs this plan] |

### New ADRs Proposed

<!--
  Decisions in this plan that warrant a new ADR.
  Create the ADR file using: cp docs/ADR/.template.md docs/ADR/NNNN-short-name.md
-->

| Proposed ADR | Decision | Status |
|-------------|----------|--------|
| [NNNN-short-name] | [What was decided and why] | Draft / Accepted |

### Open Questions

<!--
  Questions that remain unresolved after research.
  These should be resolved before or during implementation.
-->

- [Open question, if any]

## Complexity Tracking

<!--
  Fill ONLY if Constitution Check has violations that must be justified.
  Every complexity beyond what principles permit must be explicitly defended.
-->

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., extra abstraction layer] | [current need] | [why simpler approach insufficient] |

## Implementation Phases

<!--
  High-level phases. Detailed tasks go in tasks.md.
  Each phase should produce a testable increment.
-->

### Phase 1: [Foundation/Setup]
- [What gets built and why]
- **Checkpoint**: [How to verify this phase is complete]

### Phase 2: [Core Feature / US1]
- [What gets built and why]
- **Checkpoint**: [How to verify - should be independently testable]

### Phase 3: [Extensions / US2+]
- [What gets built and why]
- **Checkpoint**: [How to verify]

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| [What could go wrong] | low / medium / high | [Consequence] | [How to prevent or handle] |

## Notes

_Links to relevant docs, prior art, related features._
