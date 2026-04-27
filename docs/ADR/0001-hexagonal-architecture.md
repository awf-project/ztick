---
title: "0001: Hexagonal Architecture (Ports and Adapters)"
---

**Status**: Accepted
**Date**: 2026-03-28
**Supersedes**: N/A
**Superseded by**: N/A

## Context

The ztick scheduler needs a clean separation of concerns between business logic, adapters, and the interface layer to enable:

1. **Testability** — Core logic testable without I/O or thread dependencies
2. **Flexibility** — Replace implementations (TCP → HTTP, shell → HTTP runner) without touching domain code
3. **Clarity** — Dependencies flow inward; outer layers depend on inner, never the reverse
4. **Maintainability** — New contributors understand the codebase by its layered structure

The project follows strict conventions to enforce these properties (CLAUDE.md), requiring a formal architecture decision to guide implementation.

## Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Hexagonal (4 Layers)** | Clear dependency direction; each layer independently testable; explicit adapters for all I/O | Requires discipline to maintain boundaries; 4 layers adds ceremony for tiny features |
| **Layered (3 Layers)** | Simpler for small projects; fewer boundaries | Harder to swap adapters; infrastructure often leaks into application |
| **Flat/Monolithic** | Fastest to initial implementation | No separation; hard to test; dependencies cycle; refactoring painful |

## Decision

Adopt **hexagonal architecture** with **4 strict layers**:

```
┌──────────────────────────────────┐
│ Interfaces (CLI, Config)         │
├──────────────────────────────────┤
│ Infrastructure (TCP, Shell, Persistence) │
├──────────────────────────────────┤
│ Application (Scheduler, Storage) │
├──────────────────────────────────┤
│ Domain (Job, Rule, Runner)       │
└──────────────────────────────────┘
```

**Dependency rule**: Outer layers import from inner layers only. Inner layers NEVER import from outer.

- **Domain** (`src/domain/`) — Pure types, zero dependencies
- **Application** (`src/application/`) — Scheduler logic, depends on Domain only
- **Infrastructure** (`src/infrastructure/`) — Adapters (TCP, Shell, Persistence, Protocol), depends on Domain + Application
- **Interfaces** (`src/interfaces/`) — CLI entry point, Config, Wiring, depends on all layers

## Consequences

**What becomes easier:**
- Testing domain and application logic without mocking I/O
- Adding new adapters (e.g., HTTP runner) without touching domain
- Understanding data flow (inward dependencies are explicit)
- Porting to different platforms (swap TCP for Unix sockets)
- Code review (violations of the dependency rule are obvious)

**What becomes harder:**
- Sharing code across layers (must implement in the right layer)
- Simple one-file features (need to be split across layers)
- Adding quick hacks (the boundary enforcement prevents shortcuts)

## Constitution Compliance

| Principle | Status | Justification |
|-----------|--------|---------------|
| Hexagonal Architecture (4 layers) | Compliant | All implementation adheres to this pattern; layer separation verified via import analysis |
| TDD (RED-GREEN-REFACTOR) | Compliant | Each layer includes co-located unit tests; 95%+ domain coverage |
| No ambiguous boundaries | Compliant | Each layer has a single responsibility; imports follow strict direction |
| Minimal Abstraction | Compliant | No interfaces without 2+ implementations; single canonical `Runner` union |

## Runner Implementation Status

The `Runner` tagged union in `src/domain/` defines the set of supported runner types. The table below tracks implementation status:

| Runner | Status |
|--------|--------|
| Shell | Implemented |
| HTTP | Implemented |
| AMQP | Implemented — see [ADR-0005](0005-amqp-runner-design.md) for design decisions |

## References

- **Implementation**: See `docs/development/architecture.md` for code examples
- **ADR-0005**: `docs/ADR/0005-amqp-runner-design.md` (AMQP runner design decisions)
