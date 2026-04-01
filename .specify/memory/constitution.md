# Project Constitution v1.0.0

Governing principles for this Zig project.
All implementations must comply with these principles.

---

## Principle 1: Hexagonal Architecture

All code follows strict hexagonal/clean architecture with dependency inversion.

### Modules (inside-out)
1. **domain** (`src/domain/`) - Business logic, models, port interfaces. ZERO external dependencies.
2. **application** (`src/application/`) - Use cases, services. Depends only on domain.
3. **infrastructure** (`src/infrastructure/`) - Adapters (I/O, network). Implements domain interfaces.
4. **interfaces** (`src/interfaces/`) - CLI entry points. Entry points only.

### Rules
- domain MUST NOT depend on application, infrastructure, or interfaces
- application MUST NOT depend on infrastructure or interfaces
- All cross-module communication through interfaces defined in domain

## Principle 2: TDD Methodology

All features developed using strict TDD: RED -> GREEN -> REFACTOR.

### Coverage Requirements
- Minimum 80% line coverage
- Domain module: 95%+ coverage
- Every public function has at least one test

### Test Organization
- `test` blocks co-located with source files
- `tests/` - Integration tests via `build.zig` test steps

## Principle 3: Zig Idioms

- Explicit over implicit: no hidden control flow, no hidden allocations
- Errors as values: use `error` union types, propagate with `try`
- No `catch unreachable` or `@panic` in library code
- Prefer `comptime` over runtime when possible
- Use `std.log` for structured logging
- `zig fmt` enforced formatting

## Principle 4: Minimal Abstraction

- Simple code over clever solutions
- No interface without 2+ concrete implementations
- Prefer composition over deep abstraction hierarchies
- Use tagged unions for domain concepts
