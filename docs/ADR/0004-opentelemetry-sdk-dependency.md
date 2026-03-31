# 0004: OpenTelemetry SDK Dependency for Instrumentation

**Status**: Accepted
**Date**: 2026-03-31
**Supersedes**: N/A
**Superseded by**: N/A

## Context

F010 adds OpenTelemetry instrumentation to ztick (metrics, traces, structured logs). This requires OTLP/HTTP serialization, metric registry with atomic counters/gauges/histograms, span lifecycle management, and a dedicated exporter thread.

ADR-0002 established a zero-external-dependency philosophy (`build.zig.zon dependencies = .{}`). ADR-0003 extended this by noting system libraries (OpenSSL via `@cImport`) don't count as Zig packages. However, F010's OTLP serialization, protobuf encoding, and OTel-spec-compliant data model are substantial enough that hand-rolling them provides no unique value and introduces spec-conformance risk.

The `zig-o11y/opentelemetry-sdk` (v0.1.1) is a community-backed Zig OpenTelemetry SDK originating from an official OTel community proposal. It targets Zig 0.15.2 (matching ztick), is fetchable via `zig fetch --save`, and provides all three signals with OTLP/HTTP JSON and protobuf transport.

## Candidates

| Option | Pros | Cons |
|--------|------|------|
| **zig-o11y/opentelemetry-sdk** | OTel community-backed; Zig 0.15.2 compatible; fetchable; all 3 signals + OTLP exporters + std.log bridge; MIT license | 3 transitive deps (zig-protobuf, opentelemetry-proto, zlib); alpha (v0.1.1); breaks `dependencies = .{}` |
| **ibd1279/otel-zig** | All 3 signals; similar scope | Local path dep on zig-protobuf (not fetchable); v0.0.1; 6 stars; single maintainer |
| **Hand-rolled stdlib-only** | Zero dependencies; full control | High implementation cost (OTLP JSON, protobuf, metric registry, span model); spec-conformance risk; duplicates well-solved problems |

## Decision

Adopt **zig-o11y/opentelemetry-sdk v0.1.1** as a Zig package dependency for F010.

- Add to `build.zig.zon` via `zig fetch --save "git+https://github.com/zig-o11y/opentelemetry-sdk#v0.1.1"`
- Use `sdk.metrics` for Counter, Histogram, Gauge instruments
- Use `sdk.trace` for Span lifecycle and TracerProvider
- Use `sdk.logs` with std.log bridge for OTLP log export
- Use `sdk.otlp` exporters for OTLP/HTTP transport
- Telemetry code isolated in infrastructure layer (`infrastructure/telemetry.zig`); domain and application layers do not import the SDK directly

This is the first Zig package dependency in `build.zig.zon`, superseding the zero-Zig-package aspect of ADR-0002. The core philosophy of minimal dependencies remains — this is a justified exception for a standardized observability protocol.

## Consequences

**What becomes easier:**
- OTLP spec conformance guaranteed by the SDK (protobuf encoding, JSON encoding, resource attributes, semantic conventions)
- Significantly reduced F010 scope: no hand-rolled metric registry, serializer, or exporter thread needed
- Future OTel features (sampling, propagation, new signals) available without custom implementation
- std.log bridge provides OTLP log export with minimal wiring

**What becomes harder:**
- Dependency auditing: 3 transitive packages to track (zig-protobuf, opentelemetry-proto, zlib)
- SDK version upgrades may require code changes (alpha API)
- Build requires fetching packages (no longer fully offline-buildable from a fresh clone without `zig fetch`)
- Binary size increases due to protobuf and zlib linkage

## Trade-offs Accepted

- **Alpha status**: v0.1.1 is explicitly alpha. Mitigated by: pinning to exact version tag; telemetry is non-critical path (ztick functions normally with telemetry disabled); SDK isolatedto infrastructure layer for easy replacement.
- **Transitive dependencies**: 3 packages added. Mitigated by: all are well-scoped (protobuf codec, proto definitions, compression); zlib targeted for removal in Zig 0.16 (stdlib deflate).
- **Breaking ADR-0002**: The zero-dependency invariant served ztick well through F001-F009. OpenTelemetry is a standardized, complex protocol where hand-rolling provides negative value. This is a principled exception, not abandonment of minimalism.

## Constitution Compliance

| Principle | Status | Justification |
|-----------|--------|---------------|
| Zero external Zig dependencies | Violation (justified) | First Zig package dep; justified by OTel protocol complexity and community-standard SDK availability |
| Minimal Abstraction | Compliant | SDK provides necessary abstractions (metric instruments, exporters); no speculative wrappers added on top |
| Hexagonal Architecture | Compliant | SDK usage isolated in infrastructure layer; application layer uses thin interfaces; domain layer untouched |
| Build Simplicity | Compliant | Single `zig fetch --save` command; dependency declared in `build.zig.zon`; standard Zig package mechanism |

## References

- **SDK**: https://github.com/zig-o11y/opentelemetry-sdk
- **OTel community proposal**: https://github.com/open-telemetry/community/issues/2514
- **Spec**: `.specify/implementation/F010/spec-content.md`
- **ADR 0002**: `docs/ADR/0002-zig-language-choice.md` (zero-dependency decision this ADR relaxes)
- **ADR 0003**: `docs/ADR/0003-openssl-tls-dependency.md` (precedent for system library exception)
