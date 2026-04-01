# Tasks: [FEATURE ID] - [FEATURE TITLE]

**Prerequisites**: plan.md (required), spec.md (required)
**Generated**: [DATE]

## Format

```
- [ ] T001 [P?] [US?] Description with exact file path
```

- **`[P]`**: Can run in parallel (different files, no shared state)
- **`[US1]`**, **`[US2]`**: Which user story this task belongs to
- Include exact file paths in descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project initialization and basic structure.
No dependencies — can start immediately.

- [ ] T001 [description with file path]
- [ ] T002 [P] [description with file path]

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before ANY user story.

**CRITICAL**: No user story work can begin until this phase is complete.

- [ ] T003 [description with file path]
- [ ] T004 [P] [description with file path]

**Checkpoint**: Foundation ready — user story implementation can begin.

---

## Phase 3: User Story 1 - [Title] (P1) MVP

**Goal**: [Brief description of what this story delivers]
**Independent Test**: [How to verify this story works on its own]

<!--
  TDD order: write tests first, verify they fail, then implement.
  Models before services. Services before endpoints.
-->

- [ ] T005 [US1] [test task — write failing test first]
- [ ] T006 [P] [US1] [model/entity task with file path]
- [ ] T007 [US1] [service/logic task with file path]
- [ ] T008 [US1] [endpoint/interface task with file path]

**Checkpoint**: User Story 1 fully functional and testable independently.

---

## Phase 4: User Story 2 - [Title] (P2)

**Goal**: [Brief description of what this story delivers]
**Independent Test**: [How to verify this story works on its own]

- [ ] T009 [US2] [test task]
- [ ] T010 [P] [US2] [implementation task with file path]
- [ ] T011 [US2] [implementation task with file path]

**Checkpoint**: User Stories 1 AND 2 both work independently.

---

## Phase 5: User Story 3 - [Title] (P3)

**Goal**: [Brief description of what this story delivers]
**Independent Test**: [How to verify this story works on its own]

- [ ] T012 [US3] [test task]
- [ ] T013 [P] [US3] [implementation task with file path]

**Checkpoint**: All user stories independently functional.

---

<!--
  Add more user story phases as needed following the same pattern:
  - Goal + Independent Test
  - Tests first, then implementation
  - Checkpoint at the end
-->

---

## Dependencies & Execution Order

### Phase Dependencies

```
Setup (Phase 1)
  └─> Foundational (Phase 2)  [BLOCKS all stories]
        ├─> US1 (Phase 3)  [MVP - do first]
        ├─> US2 (Phase 4)  [can parallel with US1 if no shared state]
        └─> US3 (Phase 5)  [can parallel with US1/US2]
```

### Within Each User Story

1. Tests written and FAILING before implementation
2. Models/entities before services
3. Services before endpoints/interfaces
4. Core implementation before integration
5. Story complete and passing before next priority

### Parallel Opportunities

- Tasks marked `[P]` within the same phase can run concurrently
- After Phase 2, different user stories can proceed in parallel
- Models within a story marked `[P]` can run in parallel

---

## Implementation Strategy

### MVP First (Recommended)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (BLOCKS all stories)
3. Complete Phase 3: User Story 1 (P1)
4. **STOP and VALIDATE**: Test US1 independently
5. Continue with Phase 4, 5... in priority order

### Incremental Delivery

Each user story is a deployable/demonstrable increment:
- Setup + Foundation -> ready
- +US1 -> MVP (test, demo)
- +US2 -> enhanced (test, demo)
- +US3 -> complete (test, demo)

---

## Notes

- Commit after each task or logical group
- Stop at any checkpoint to validate independently
- Avoid: vague tasks, same-file conflicts, cross-story dependencies
