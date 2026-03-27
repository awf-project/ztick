# Development

Understanding-oriented guides for developers contributing to ztick.

## Contents

- **[Architecture](architecture.md)** — Hexagonal layer structure and design rationale
  - Layer separation (Domain, Application, Infrastructure, Interfaces)
  - Dependency inversion and testability
  - Testing strategy for each layer

- **[Building](building.md)** — Compiling, testing, and packaging
  - Debug and release builds
  - Running unit and functional tests
  - Performance profiling
  - Release checklist

- **[Contributing](contributing.md)** — Code style and submission guidelines
  - Branch and PR workflow
  - Zig conventions
  - Documentation standards
  - Types of contributions

## Quick Start for Developers

### 1. Set Up

```bash
git clone https://github.com/pocky/ztick.git
cd ztick
zig build test  # Verify environment
```

### 2. Understand the Code

Start with [Architecture](architecture.md):
- 4-layer hexagonal design
- Domain first (pure types), then outward
- Co-located tests per layer

### 3. Make Changes

Follow these rules:
1. Keep dependencies flowing inward
2. Write tests alongside code
3. Run `zig fmt .` before committing
4. Use descriptive commit messages

### 4. Test

```bash
zig build test                    # All tests
zig build test --test-filter domain  # Layer-specific
zig fmt --check .                 # Format check
```

### 5. Submit PR

- Push to a feature branch
- Open PR with clear description
- Address review feedback
- Merge once approved

---

## Architecture Decisions

Key decisions are documented in [ADRs](../ADR/):

| Decision | Location | Rationale |
|----------|----------|-----------|
| Hexagonal architecture | [Architecture](architecture.md) | Testability, dependency control |
| Zig language choice | [ADR 0002](../ADR/0002-zig-language-choice.md) | Fast compile, explicit memory, no runtime |
| Binary persistence format | [Persistence](../reference/persistence.md) | Performance, durability |
| Thread model | [Architecture](architecture.md) | 3 threads: Controller, Database, Processor |

## Key Files

```
src/
├── domain/           # Pure types (Job, Rule, Runner, etc.)
├── application/      # Scheduler logic (storage, query handling)
├── infrastructure/   # Adapters (TCP, shell, persistence, protocol)
├── interfaces/       # CLI, config loading, component wiring
└── functional_tests.zig  # End-to-end tests

build.zig            # Build configuration
build.zig.zon        # Version and dependencies
```

## Development Workflow

### Daily Work

1. Create a feature branch: `git checkout -b feature/my-feature`
2. Edit code in `src/`
3. Run tests: `zig build test`
4. Format: `zig fmt .`
5. Commit: `git commit -m "feat: description"`
6. Push and open PR

### Testing Locally

```bash
# Run all tests
zig build test

# Run specific layer tests
zig build test --test-filter domain

# Functional/integration tests
zig build test-functional

# Format check
zig fmt --check .
```

### Debugging

```bash
# Add debug logging
std.debug.print("value: {}\n", .{value});

# Run with debug build
zig build
./zig-out/bin/ztick --config debug.toml

# Use a debugger
gdb ./zig-out/bin/ztick
```

## Code Quality Standards

- **Coverage**: 80%+ overall (95%+ domain)
- **Formatting**: 100% `zig fmt` compliant
- **Tests**: All layers tested
- **Docs**: Public APIs documented
- **Errors**: No panics in library code

## Common Tasks

### Add a New Domain Type

1. Create `src/domain/my_type.zig`
2. Define the struct/enum
3. Add unit tests in the same file
4. Import in `src/domain.zig`
5. Reference in Application/Infrastructure as needed

### Implement a New Adapter

1. Create `src/infrastructure/my_adapter.zig`
2. Implement the interface
3. Add tests for error cases
4. Import in `src/infrastructure.zig`
5. Wire into `src/main.zig`

### Update Configuration

1. Modify `src/interfaces/config.zig` parser
2. Add new field to `Config` struct
3. Update `src/main.zig` to use the field
4. Document in `docs/reference/configuration.md`
5. Add tests to `src/interfaces/config.zig`

## Performance Considerations

ztick is designed to be lean:

- **Memory**: All allocations are explicit and tracked
- **CPU**: Framerate is configurable; single-threaded scheduler tick
- **I/O**: Binary format minimizes parsing overhead

Profile with:

```bash
zig build -Doptimize=ReleaseSafe
valgrind --tool=callgrind ./zig-out/bin/ztick

# View results
kcachegrind callgrind.out.*
```

## Resources

- **[Zig Documentation](https://ziglang.org/documentation/)**
- **[Hexagonal Architecture](https://en.wikipedia.org/wiki/Hexagonal_architecture_(software))**

## Getting Help

- **Architecture questions**: Review [Architecture](architecture.md) or open a discussion
- **Build issues**: Check [Building](building.md) troubleshooting section
- **Code review**: See [Contributing](contributing.md)

## See Also

- **[User Guide](../user-guide/)** — How to use ztick
- **[Reference](../reference/)** — API and protocol specs
