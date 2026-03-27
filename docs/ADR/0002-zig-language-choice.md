# 0002: Zig Language Choice

**Status**: Accepted
**Date**: 2026-03-28
**Supersedes**: N/A
**Superseded by**: N/A

## Context

ztick is a time-based job scheduler that needs:

1. **Fast compilation** — Developers need tight feedback loops; CI must stay fast
2. **Minimal dependencies** — Reduce supply chain risk; audit the entire stack
3. **Runtime simplicity** — Single-threaded core with 3 helper threads; no need for complex async runtimes
4. **Explicit memory control** — Scheduler needs predictable, deterministic allocation
5. **Small deployment** — Binary should be self-contained, deployable to minimal environments

## Candidates

| Option | Pros | Cons |
|--------|------|------|
| **Zig** | Blazing fast compile (2-3 sec); stdlib only; explicit allocators; minimal binary | Less mature; smaller community; no garbage collection |
| **Rust** | Mature ecosystem; strong type system; large community | Slow compile (30+ sec for similar projects); heavy dependency graphs; overkill async ecosystem for this domain |
| **C** | Extremely fast; minimal binary; portable | No type safety; manual memory is error-prone; no modern tooling |
| **Go** | Fast compile; solid stdlib; deployment story | Garbage collection (unpredictable latency); heavier binary |

## Decision

**Build ztick in Zig 0.14.1**.

The scheduler's requirements align perfectly with Zig's strengths:

1. **Zero dependencies**: ztick uses only `std` — no external packages needed
2. **Explicit allocator passing**: The scheduler needs predictable allocation; Zig forces this via function parameters
3. **Comptime for correctness**: Use `comptime` for protocol validation, type dispatching
4. **Build speed**: 2-3 seconds for a full build in CI
5. **Binary size**: ~3MB static binary, trivially deployable

## Consequences

**What becomes easier:**
- Compile time for developers (2-3 seconds)
- Auditing dependencies (none; only Zig stdlib)
- Understanding memory behavior (all allocations explicit)
- Deploying to constrained environments (binary ~3MB static)
- Adding features without bloating a dependency graph

**What becomes harder:**
- Recruiting developers (fewer Zig developers in industry)
- Reusing library code from larger ecosystems
- Async I/O patterns (must be threaded instead)
- Debugging runtime issues (smaller community, fewer resources)

## Implementation Notes

**Key design decisions**:
- i64 nanosecond timestamps (matches binary format, no datetime library needed)
- Hand-written minimal TOML parser (config is simple: 3 sections, 4 values)
- Custom bounded channel over `std.event` (0.14.1 async unstable)
- Shell runner only

## Constitution Compliance

| Principle | Status | Justification |
|-----------|--------|---------------|
| Zig Idioms (error unions, comptime, std.log) | Compliant | Error unions throughout; no `@panic()` in library code |
| Minimal Abstraction | Compliant | No external packages; stdlib only; language provides necessary primitives |
| No unsafe runtime | Compliant | Zig's memory safety model with explicit allocators prevents undefined behavior |
| Build simplicity | Compliant | Single `build.zig` file; no build scripts or external tools |

## Trade-offs Accepted

- **Zig immaturity**: 0.14.1 is recent. Mitigated by: pinning version in CI, stable stdlib APIs, co-located tests for regression detection
- **Smaller ecosystem**: Zig has fewer libraries. Mitigated by: ztick needs no external deps; protocol parser/TOML parser hand-written per specification
- **Community size**: Zig community is smaller. Mitigated by: architecture is well-documented; code is self-explanatory; contribution guidelines clear

## References

- **Architecture**: `docs/development/architecture.md`
- **Build Guide**: `docs/development/building.md`
- **Zig Docs**: https://ziglang.org/documentation/
