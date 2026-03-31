# Contributing to ztick

Thank you for considering contributing to ztick. This document explains how to contribute.

## Code of Conduct

This project follows the [Contributor Covenant](.github/CODE_OF_CONDUCT.md). By participating, you agree to uphold this code.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, check existing issues.

**Bug Report Template:**
- **Description**: Clear description of the bug
- **Steps to Reproduce**: Numbered steps
- **Expected Behavior**: What should happen
- **Actual Behavior**: What actually happens
- **Environment**: OS, Zig version, ztick version

### Suggesting Features

Open an issue with:
- **Problem**: What problem does this solve?
- **Solution**: Proposed solution
- **Alternatives**: Other solutions considered

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run tests (`make test`)
5. Run linter (`make lint`)
6. Commit with conventional commits (`feat: add amazing feature`)
7. Push to your fork (`git push origin feature/amazing-feature`)
8. Open a Pull Request

## Development Setup

```bash
# Clone your fork
git clone https://github.com/your-username/ztick.git
cd ztick

# Build
make build

# Run tests
make test

# Run linter
make lint
```

### Prerequisites

- Zig 0.15.2+
- OpenSSL development headers (for TLS support)
- Make

## Style Guide

### Code Style

- Follow Zig standard conventions (`zig fmt`)
- Run `make lint` before committing
- Follow existing patterns in codebase
- Types: PascalCase. Functions: snake_case. Constants: snake_case

### Architecture

This project follows Hexagonal/Clean Architecture with four strict layers:

```
domain/ → application/ → infrastructure/ → interfaces/
```

- Domain layer has zero dependencies (pure data and types)
- Each layer has a barrel export file (e.g. `domain.zig`)
- Import layers through barrels only
- Use tagged unions for protocol and runner types
- Use error unions for fallible operations

### Code Quality Requirements

All pull requests must pass quality checks before merge.

**Required checks:**

1. **Linting**: `make lint` must pass with zero issues
2. **Testing**: `make test` must pass with no failures
3. **Build**: `make build` must succeed

**PR Expectations:**
- CI pipeline shows all checks passing
- No linter warnings or errors
- New code includes tests
- Documentation updated if behavior changes

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <subject>
```

**Types**: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`

**Examples:**
- `feat(protocol): add QUERY command`
- `fix(persistence): handle corrupted frame`
- `docs(readme): update configuration section`

**Rules:**
- Max 50 characters for subject
- Imperative mood ("add" not "added")
- No period at the end

### Testing

- Co-locate unit tests in `test` blocks within source files
- Integration tests go in `src/functional_tests.zig`
- Verbose test names describe behavior (e.g. `test "tick processes query request and routes response"`)
- Use `std.testing.tmpDir` for test files; never hardcode `/tmp` paths
- Layer-specific targets: `zig build test-domain`, `test-application`, `test-infrastructure`, `test-interfaces`, `test-functional`

## Project Structure

```
src/
├── domain/          # Pure data types, zero dependencies
├── application/     # State machines, storage, use cases
├── infrastructure/  # IO adapters (TCP, persistence, telemetry)
└── interfaces/      # CLI, config parsing
docs/                # ADRs, user guides, reference
example/             # Example configuration files
```

## Review Process

1. Maintainers review within 1-2 weeks
2. Address feedback in new commits
3. Squash commits before merge (if requested)
4. Celebrate your contribution!

## Questions?

Open an issue with the `question` label.
