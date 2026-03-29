# Documentation

This directory contains documentation for ztick, organized by the **Diátaxis** framework:

## [Tutorials](tutorials/) — Learning-Oriented

Step-by-step guides for users new to ztick.

- **[Getting Started](tutorials/getting-started.md)** — Build, run, and verify your first ztick instance

## [User Guide](user-guide/) — Task-Oriented

Practical how-to guides for common operations.

- **[Creating Jobs](user-guide/creating-jobs.md)** — Define jobs with execution times and query by prefix
- **[Writing Rules](user-guide/writing-rules.md)** — Pattern-match jobs to actions
- **[Configuration](user-guide/configuration.md)** — Set up logging, listen addresses, and persistence

## [Reference](reference/) — Information-Oriented

Complete technical specification and API documentation.

- **[Configuration Schema](reference/configuration.md)** — All TOML options and defaults
- **[Protocol](reference/protocol.md)** — Client communication protocol
- **[Data Types](reference/types.md)** — Job, Rule, Runner, Execution structures
- **[Persistence Format](reference/persistence.md)** — Binary logfile encoding

## [Development](development/) — Understanding-Oriented

Architecture, design decisions, and contribution guidelines.

- **[Hexagonal Architecture](development/architecture.md)** — Layer separation and dependency flow
- **[Building the Project](development/building.md)** — Compile from source, run tests
- **[Contributing](development/contributing.md)** — Code style, testing, submission process

## [Architecture Decision Records (ADRs)](ADR/)

Rationale behind major technical choices.

---

**How to use this documentation:**

- **New to ztick?** Start with [Getting Started](tutorials/getting-started.md)
- **Want to complete a task?** Check the [User Guide](user-guide/)
- **Need technical details?** See [Reference](reference/)
- **Curious about design?** Read [Development](development/) and [ADRs](ADR/)
