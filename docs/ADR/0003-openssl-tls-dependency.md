# 0003: System OpenSSL for Server-Side TLS

**Status**: Accepted
**Date**: 2026-03-30
**Supersedes**: N/A
**Superseded by**: N/A

## Context

F006 adds TLS support to ztick's TCP server (FR-001). This requires a server-side TLS implementation capable of accepting connections, performing handshakes, and wrapping streams.

Zig's stdlib `std.crypto.tls` provides **client-side TLS only** — the `std/crypto/tls/` directory contains only `Client.zig` as of Zig 0.15.2. There is no server-side handshake capability in the stdlib.

ADR 0002 chose Zig specifically for its zero-dependency philosophy, with `build.zig.zon dependencies = .{}`. Adding TLS support forces the first decision to reach outside the Zig stdlib, creating tension with this foundational constraint.

## Candidates

| Option | Pros | Cons |
|--------|------|------|
| **System OpenSSL via `@cImport`** | Zig's C interop is zero-overhead and first-class; OpenSSL is universally available and battle-tested; `build.zig.zon dependencies` stays `= .{}` | Adds platform dependency on `libssl-dev`; TLS behavior tied to system OpenSSL version |
| **iguanaTLS (Zig package)** | Pure Zig; no system library dependency | Zig 0.15.2 compatibility unverified; appears unmaintained; adds entry to `build.zig.zon dependencies`, breaking zero-Zig-package invariant |
| **Defer TLS (abstraction only)** | No new dependencies; lowest risk | Does not deliver functional TLS (FR-001, US1); defers the core feature deliverable |

## Decision

Use **system OpenSSL** (libssl + libcrypto) accessed via Zig's `@cImport` C interop.

- A new infrastructure module `src/infrastructure/tls_context.zig` isolates all OpenSSL FFI at a clean boundary
- `build.zig` conditionally links `libssl` and `libcrypto` only when the TLS module is compiled; plaintext-only builds remain fully zero-dependency
- `build.zig.zon dependencies` stays `= .{}` — system libraries linked via `linkSystemLibrary` are not Zig packages

## Consequences

**What becomes easier:**
- Delivering functional TLS (FR-001 compliance) without adding Zig package dependencies
- Auditing the TLS implementation path (one file: `tls_context.zig`)
- Reverting: remove `tls_context.zig` and the conditional `linkSystemLibrary` calls

**What becomes harder:**
- Builds now require `libssl-dev` on development machines and CI (`apt-get install libssl-dev` on Debian/Ubuntu)
- Platform portability: system OpenSSL may not be present on minimal musl-based containers
- TLS behavior tied to the system's OpenSSL version

## Trade-offs Accepted

- **System library dependency**: Plaintext-only builds remain zero-dependency. Conditional linking in `build.zig` ensures developers who don't need TLS are unaffected.
- **OpenSSL version variance**: OpenSSL's C API is stable across major versions. The implementation uses only core primitives (`SSL_CTX_new`, `SSL_accept`, `SSL_read`, `SSL_write`).
- **Platform availability**: OpenSSL is installed on every mainstream Linux distribution and macOS. CI adds `libssl-dev` as a build prerequisite.

## Constitution Compliance

| Principle | Status | Justification |
|-----------|--------|---------------|
| Zero external Zig dependencies | Compliant | `build.zig.zon dependencies = .{}` unchanged; system libs are not Zig packages |
| Minimal Abstraction | Compliant | TlsContext and Connection each have a single, justified purpose; no speculative interfaces |
| Hexagonal Architecture | Compliant | All OpenSSL FFI isolated in `infrastructure/tls_context.zig`; domain and application layers untouched |
| Build Simplicity | Compliant | Conditional `linkSystemLibrary` in `build.zig`; no new build scripts or tooling |

## References

- **Spec**: `.specify/implementation/F006/spec-content.md`
- **Plan**: `.specify/implementation/F006/plan.md`
- **Implementation**: `src/infrastructure/tls_context.zig`, `src/infrastructure/tcp_server.zig`
- **ADR 0002**: `docs/ADR/0002-zig-language-choice.md` (zero-dependency decision this ADR extends)
