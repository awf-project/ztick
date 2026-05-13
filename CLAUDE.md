## Architecture Rules

- Use hexagonal layering: domain (entities), application (use cases), infrastructure (adapters), interfaces (CLI/config). Organize modules with barrel exports
- Use tagged unions for protocol/runner/instruction types; error unions for fallible operations. All variants declare payloads with `struct {}` syntax even when empty for consistent destructuring
- Four strict layers: domain/ (pure data, zero deps), application/ (state machines, storage), infrastructure/ (IO adapters), interfaces/ (CLI, config)
- Each layer has a barrel export file (domain.zig, application.zig, infrastructure.zig, interfaces.zig); import layers through barrels only — direct cross-layer imports break encapsulation
- Logfile dump must never load entire file into memory; implement sequential frame reads to comply with NFR-001 scaling constraint
- Use Process.execute() for all background operations; never manually construct Process structs in application layer to maintain API consistency
- Send ERROR response for all protocol validation failures before disconnecting; never silently close connections on parse errors like RULE SET with missing executable
- Authenticated HTTP endpoints must explicitly include 401 Unauthorized response schemas in OpenAPI specs; inherited security definitions don't auto-document client error handling paths
- Maintain CRUD endpoint parity in OpenAPI specs; if GET /jobs/{id} exists, corresponding GET /rules/{id} must exist or be explicitly documented as omitted in spec comments
- Implement configuration parsing for new subsystems before wiring them as application threads; verify [http], [controller], [database] sections exist in config.zig before feature completion
- Expose file descriptors from TLS stream wrappers via accessor methods when low-level socket operations are required
- Implement connection-level authentication as TCP middleware; never add AUTH as Instruction variant to maintain connection-scoped isolation
- Maintain strict layer separation during feature merges; keep application-layer code (session management, namespace enforcement) isolated to its originating feature branch, reference-only in dependent tasks

## Performance Principles

- **Zero allocation in hot paths**: tick loop (main.zig:237-258), Channel operations, request routing must allocate nothing per-iteration. Use stack buffers (`var buf: [N]T = undefined`) and pre-sized ArrayListUnmanaged
- **Batch over iterate**: prefer `Channel.drain(&buf)` over repeated `receive()` to amortize lock acquisition; tick uses 1024-element drain buffer for request batching
- **Static buffers for I/O**: 64KB persistence read buffer (backend.zig:52), 8KB HTTP read/write buffers (http.zig:118-122). Never malloc per syscall — reuse fixed-size buffers across iterations
- **Drain non-blocking before blocking**: hot loops do `try_receive()` first to drain stale work, then `receive()`/`timedWait()` to sleep. Separates fast path from slow path
- **@memcpy over loops** for slice copies; compiler emits SIMD/rep movsb. Use `std.mem.copyForwards`/`copyBackwards` only for overlapping ranges (execution_client.zig:69)
- **Big-endian binary serialization**: use `std.mem.writeInt(T, dst, val, .big)` and `std.mem.readInt(T, src, .big)`; never build/parse byte sequences manually
- **Power-of-2 channel capacities** when feasible for cheap modulo via mask; current Channel uses generic modulo (channel.zig:42-67)
- **Optimize mode**: production builds use `-Doptimize=ReleaseSafe` (default); reach for `ReleaseFast` only when sanitizer + functional tests prove correctness, never for crypto/auth code
- **Annotate cold paths**: use `@branchHint(.cold)` on error returns and `.unlikely` on validation failures in hot loops; the compiler reorders code blocks accordingly
- **Inline tiny accessors**: mark single-statement getters `inline fn` only when profiling shows call overhead; otherwise let the compiler decide

## Memory & Allocators

- **GeneralPurposeAllocator** for application root (main.zig:1090); single instance threaded down via `std.mem.Allocator` parameter — never global allocators
- **ArenaAllocator** for bulk-load/parse sessions where everything dies together: persistence decode (backend.zig:137), config parsing. Call `reset(.retain_capacity)` between batches to keep backing memory hot
- **Static buffers** (`var buf: [N]u8 = undefined`) for I/O scratch; never heap-allocate per-request payload buffers
- **ArrayListUnmanaged(T) is the default**; never use `ArrayList(T)` (the managed variant carries a pointer to allocator and prevents value-copy in struct fields). Pass allocator explicitly to `append`, `appendSlice`, `toOwnedSlice`
- **Ownership single-writer**: each allocation has exactly one `deinit()` call site. Document ownership in struct field comments when non-obvious. When struct is copied by value, only the *originally constructed* copy may deinit (ArrayListUnmanaged backing memory is shared)
- **errdefer for partial init**: every multi-step allocation in a constructor uses errdefer to roll back on later failure; never leak on partial-init error paths
- **Dupe at boundaries**: scheduler stores pointers to instruction strings without copying; TCP/HTTP controllers must `allocator.dupe(u8, …)` before sending to the request channel (same pattern as `build_instruction` in tcp_server.zig)
- **toOwnedSlice() to transfer ownership** instead of copying; consumer must free with same allocator
- **Testing allocator** (`std.testing.allocator`) in every unit test — leaks fail the test. Functional tests use a fresh GPA with `defer _ = gpa.deinit()` for end-to-end leak detection

## Concurrency

- **Four-thread architecture**: controller (TCP server), database (scheduler tick loop), processor (job executor), http (REST API — optional, enabled via [http] config section)
- **Bounded FIFO channels** (Channel(T) at infrastructure/channel.zig) with mutex + condition variables for inter-thread communication; capacity 64. Generic over T, circular buffer with head/tail/count
- **Channel signaling**: `send()` signals `not_empty` + optional external `notify_condition` (used by Clock to wake the database thread early); `receive()` signals `not_full`. `try_send`/`try_receive` are non-blocking and return error.ChannelFull/ChannelEmpty
- **Atomic flag** (`std.atomic.Value(bool)`) for cross-thread shutdown coordination; use `.acquire`/`.release` ordering for visibility, `.monotonic` only for counters that don't gate other reads
- **Per-connection ResponseRouter** with mutex-guarded AutoHashMap; each TCP connection registers its own response channel. Routing uses `try_send` to avoid blocking the database thread on slow clients
- **Shutdown order**: join controller → join http (if enabled) → store false to running → close request channel → join database → close exec channel → join processor. Closing channels before joining unblocks `receive()` waiters and prevents deadlock
- **Memory orderings**: `.release` on the producer side, `.acquire` on the consumer side; never use `.seq_cst` unless explicitly required for total ordering across multiple atomics
- **Clock pattern** (clock.zig:31-45): `timedWait(mutex, wait_ns)` instead of busy-loop polling; external producers can wake early via shared condition variable

## Protocol (TCP)

- Line-based text protocol over TCP; default listen 127.0.0.1:5678
- SET instruction: `SET <job_id> <timestamp_ns|YYYY-MM-DD HH:MM:SS>\n`; RULE SET: `RULE SET <rule_id> <pattern> <runner_type> [args...]\n`
- Responses: `<request_id> OK\n` or `<request_id> ERROR\n`
- Quoted strings supported: `"value with spaces"`, escapes `\"` and `\\`
- Timestamps: nanoseconds since Unix epoch (i64); datetime parsing supports years 1970+
- Parser uses ArrayListUnmanaged for tokens (protocol/parser.zig:34-43); single-pass tokenization with quote-aware splitter

## Protocol (HTTP)

- RESTful JSON API over HTTP/1.1; disabled by default, enabled via `[http] listen` in config
- Uses `std.http.Server` with the new 0.15 Reader/Writer interface pattern: `stream.reader(&buf)` → `.interface()` passed to `http.Server.init`. Never parse HTTP manually
- OpenAPI 3.1.1 spec embedded via `@embedFile` from src/infrastructure/openapi.json with comptime version injection (http.zig:34-48 — uses `@setEvalBranchQuota(200_000)` for compile-time string substitution); single source of truth, colocated with consumer
- Endpoints: GET/PUT/DELETE /jobs/{id}, GET /jobs?prefix=, GET/PUT/DELETE /rules/{id}, GET /rules?prefix=, GET /health, GET /openapi.json
- DELETE returns 204 No Content; PUT/GET return 200 with JSON body; errors return 400/401/404/405/413 with `{"error":"message"}`
- Optional Bearer token authentication; /health and /openapi.json are public (no auth required)
- HTTP thread shares `Channel(query.Request)` and `ResponseRouter` with TCP controller and database threads — no duplicated request pipeline

## Persistence

- Append-only logfile with 4-byte big-endian length-prefixed framing per entry; no mid-file mutation
- Binary encoding (persistence_codec.zig): type byte + u16 big-endian length-prefixed strings + i64 big-endian timestamps + u8 status. Use `std.mem.writeInt(T, slice, val, .big)` exclusively
- Compression: deduplicate by ID → write to .tmp → atomic rename to .compressed → delete source
- On load: 64KB read buffer (backend.zig:52), parse frames into a carry buffer, decode entries into an arena allocator (arena kept for lifetime; `reset_decode_arena` swaps it on reload)
- Streaming dump (interfaces/dump.zig) reads frames sequentially without loading the whole file — required for NFR-001

## Configuration

- Custom TOML parser; sections: [log] (level), [controller] (listen), [database] (fsync_on_persist, framerate, logfile_path), [http] (listen), [telemetry], [shell]
- CLI flag: `-c`/`--config` for config path; defaults applied when file missing; max file size 1MB
- Framerate range: 1-65535 (u16); log levels: off, error, warn, info, debug, trace
- HTTP server disabled by default; enabled only when [http] section with listen key is present

## Build System

- **Zig 0.15.2 exact minimum** (build.zig.zon); no compatibility shims for older versions
- Minimal dependencies — zig-o11y/opentelemetry-sdk v0.1.1 for telemetry (ADR-0004), system OpenSSL via C bindings for TLS (ADR-0003), sam701/zig-cli (zig-0.15 branch) for argument parsing, stdlib for everything else
- `make build`, `make test`, `make lint` wrap zig build with `--summary all`
- Layer-specific test targets: `zig build test-domain`, `test-application`, `test-infrastructure`, `test-interfaces`, `test-functional`, `test-all`
- **Sanitizer test targets** (build.zig:161-206): `.sanitize_c = .full` (heap overflow detection) and `.sanitize_thread = true` (ThreadSanitizer for data races) on dedicated test binaries; run before any concurrency change
- Version single source of truth: `build.zig.zon` → `build_options` module → `version.zig` re-export → injected into OpenAPI spec at compile time
- TLS linking is conditional via build_root file probe; wraps `linkLibC()` + `linkSystemLibrary("ssl"/"crypto")` only when src/infrastructure/tls_context.zig exists

## Zig 0.15.2 Idioms

- **Reader/Writer interface pattern**: use `stream.reader(&buf)` then `.interface()` for `std.http.Server` and friends; the old `std.io.Reader(T)` generic factory is obsolete in 0.15
- **`std.mem.splitScalar(u8, input, '\n')`** for single-byte delimiters; `splitSequence` for multi-byte. The old `split` function is gone
- **`std.AutoHashMapUnmanaged(K, V)`** for integer/struct keys, **`std.StringHashMapUnmanaged(V)`** for `[]const u8` keys; both prefer Unmanaged variants for the same reasons as ArrayListUnmanaged
- **Generic via comptime type parameter**: `pub fn Channel(comptime T: type) type` returns an anonymous struct; `pub fn SchedulerWith(comptime Backend: type) type` for storage polymorphism
- **Comptime callbacks**: pass functions as `comptime callback: fn (@TypeOf(context)) ?i64` (clock.zig:11-17); the compiler monomorphizes per call site, eliminating indirect call overhead
- **Reflection via @typeInfo()**: walk `.@"union".fields` / `.@"struct".fields` to extract types by name (telemetry.zig:22-52); use this to wire protobuf payloads without boilerplate. Unions/structs are namespaced via `@"union"` literal because they're keywords
- **Named result blocks**: `const x = if (cond) blk: { …; break :blk value; } else other;` — preferred over chained ternaries for multi-step computation
- **`@intCast(value)`** for narrowing/widening with safety checks in Debug/ReleaseSafe; **`@as(T, value)`** for explicit type coercion when no checked conversion is needed; **`@enumFromInt`/`@intFromEnum`** for enum boundaries
- **`@embedFile()` + comptime processing**: bundle assets at build time and transform them with `@setEvalBranchQuota` for non-trivial compile-time loops (http.zig:34-48)
- **Optional unpack with capture**: `if (self.persistence) |*p| p.deinit();` — `|*p|` borrows by pointer, `|p|` copies by value; choose based on lifetime needs
- **Error sets named with `Error` suffix**: `ConfigError`, `SendError`, `ParseError`, `DecodeError`. Combine via `error{...} || OtherError` rather than catch-all `anyerror`
- **`@branchHint(.cold)`** at the top of error-return blocks; `.likely`/`.unlikely` inside hot conditional branches when measurement justifies it

## Naming Conventions

- Types: PascalCase (Job, ShellRunner, ParseResult). Functions: snake_case (handle_query, encode_job). Constants: snake_case (max_entry_size)
- Error types suffixed with Error (ConfigError, SendError, ParseError, DecodeError)
- Abbreviations: ch (channel), req/resp (request/response), instr (instruction), id (identifier), ns (nanoseconds)
- Comptime type-returning functions use PascalCase (Channel, SchedulerWith) since they produce types

## Hot Paths

- **Tick loop** (main.zig:237-258, runs every 1/framerate seconds): drain exec_response_ch → drain request_ch (1024 batch) → scheduler.tick → drain pending executions. Any allocation here is a regression
- **Scheduler.tick** (scheduler.zig:238-255): iterates jobs ready for execution; rule lookup is O(1) StringHashMap
- **Channel.drain** (channel.zig:104-115): single locked region copies all available items into caller buffer; preferred over per-item receive loop
- **ResponseRouter.route** (tcp_server.zig:48-84): mutex-guarded HashMap lookup + non-blocking try_send; never blocks producer if subscriber is slow
- **Persistence encode/decode** (persistence_codec.zig): direct @memcpy + writeInt, no string formatting, no JSON
- **Subprocess fan-out** (run_processor): single-threaded blocking receive — parallelism comes from spawning subprocesses, not from threading the executor

## Observability

- OpenTelemetry via zig-o11y/opentelemetry-sdk v0.1.1; instruments live in application/instruments.zig and are optional (telemetry disabled = `?Instruments` is null)
- Hot paths annotate spans with `setAttribute` only inside `if (instruments)` guards; never compute attributes when instruments is null
- Custom OTLP exporter (telemetry.zig:57-224) injects resource attributes into ResourceSpans because SDK v0.1.1 doesn't propagate them; uses comptime reflection to avoid boilerplate field accessors
- Counters/gauges: `jobs_scheduled`, `jobs_removed`, `rules_active`, `execution_duration_ms` (histogram)

## Common Pitfalls

- Close channels before joining threads to prevent deadlocks; document shutdown sequence explicitly
- Try `openFile(.write_only)` first, fall back to `createFile` for new logfiles; handles both append and initialization
- Pre-allocate capacity in thread tracking list before spawning; ensure append cannot fail due to OOM and orphan spawned threads
- Remove thread handles from tracking list after joining; never accumulate handles indefinitely as this causes O(n) memory growth
- Use `std.json.Stringify` for all JSON serialization; never build JSON strings manually. Use `std.json.parseFromSlice` for deserialization into typed structs
- For follow mode initial offset: subtract remaining partial-frame bytes from file length, not file length itself; starting at file end skips incomplete frames
- Never silently ignore persistence decode errors; emit warnings to stderr with byte offset for each failure to aid debugging
- When copying structs containing ArrayListUnmanaged or similar shared-backing types, ensure only the owning copy calls deinit; non-owning copies must be dropped without cleanup to prevent double-frees
- Retain .to_compress file on failed atomic rename during compression; verify destination non-existence before overwrite to prevent silent data loss during file rotation
- Use monotonic time or atomic counters for compression intervals; avoid wall-clock subtraction which wraps on NTP stepback causing infinite compression loops
- Add generated compression artifacts (.compressed, .to_compress) to .gitignore; never stage test output files or temporary persistence artifacts
- Always log failed background compression at ERROR level with .to_compress file path; retention of orphaned compression files is required for data recovery
- Always validate shell executables with execute mode (`.{ .mode = .execute }`), not default read-only mode; default mode misses executable permission failures that fail at runtime
- Always unescape TOML escape sequences when parsing array values; skipping escape bytes and copying raw backslashes produces literal backslashes instead of unescaped values
- Never duplicate specification details across files (openapi.json, http-api.md, types.md); maintain single source of truth per spec element (schema descriptions, format rules, field definitions)
- Never commit stub barrel files without implementation; add `@compileError` to unimplemented public functions to prevent partial feature merges
- Add all compiled binaries and build artifacts (test_zig, *.o, *.a, *.so) to .gitignore; build outputs must never be staged or committed
- Enforce 5-second auth timeout using poll-based socket reads; close connection if AUTH not received within timeout
- Initialize TLS contexts identically in test and production code; apply identical guard conditions (config presence checks) to prevent environment-specific bugs
- Never reimplement logic from merged features; if F011 auth was completed, F018 should only reference it via config wiring without adding session management code
- Never rely on final-diff analysis for feature verification; ensure all planned files are modified and build/test complete, since implementation may span multiple earlier commits
- Always keep feature branches scoped to plan; never commit unplanned configuration changes (.awf/, build system, deployment files) as scope-creep risks team workflows
- Don't reach for `ArrayList(T)` (managed) — it stores an allocator pointer and breaks value-copy semantics in struct fields. `ArrayListUnmanaged(T)` is the default
- Don't use `std.io.Reader(T)`/`std.io.Writer(T)` factory generics — they're removed in 0.15. Use `stream.reader(&buf).interface()` and `stream.writer(&buf).interface` instead
- Don't allocate per-iteration in tick(), Channel.drain(), or request routing — these are the hottest paths in the system
- Don't use `.seq_cst` memory ordering by default — `.acquire`/`.release` is sufficient for producer/consumer patterns and is significantly cheaper on weak-memory architectures (ARM, Apple Silicon)

## Test Conventions

- Co-locate unit tests in test blocks within source files; use functional_tests.zig for integration tests
- Verbose test names describe behavior (e.g., `test "tick processes query request and routes response"`)
- Always use `std.testing.tmpDir` for test files; never hardcode /tmp paths which create race conditions across parallel test execution
- Always verify unit tests execute through `zig build test-<layer>` targets, not just direct `zig test`; barrel export chains may prevent test discovery by the build system
- Error-handling functions and memory-cleanup helpers require isolated unit tests; integration test coverage alone is insufficient for internal functions with side effects
- Use `std.testing.allocator` (the test allocator) in unit tests — it detects leaks per-test. Functional tests instantiate a fresh `GeneralPurposeAllocator(.{})` with `defer _ = gpa.deinit()` for end-to-end leak detection
- Module barrel `test {}` blocks reference all submodules (`_ = domain; _ = application; …`) to force compilation and discovery of nested tests
- Run sanitizer test targets (ThreadSanitizer + heap sanitizer) before merging any change to channel.zig, scheduler.zig, or thread orchestration in main.zig

## Review Standards

- Normalize all function names to snake_case, including private functions; remove dead code completely
- Verify implementation matches the original specification (e.g., protocol format, timestamp parsing, command definitions)
- Never name tests after implementation internals (e.g., 'has no payload'); name them after observable behavior from the caller's perspective (e.g., 'returns formatted rules')
- HTTP DELETE operations must return 204 No Content for successful deletions; return 200 only when response body is present (violates client expectations)
- Verify all planned components are implemented before merge; HTTP controller requires `std.http.Server` routing, json codec (`std.json`), [http] config section, and threading — all must compile and pass tests
- Use `std.http.Server` for HTTP request/response handling; never parse HTTP manually. Use `request.respond()` for responses, `iterateHeaders()` for custom headers
- Dupe all instruction string identifiers before sending to scheduler via Channel; scheduler stores pointers without copying (same ownership pattern as TCP server's build_instruction)
- Always verify scope alignment before merge; reject PRs that include logic from non-target features (e.g., F011 auth session management should not appear in F018 branch)
- Documentation file changes (docs/reference/*, docs/development/*, README) must be explicitly planned in task scope; reject PRs that add unplanned documentation changes
- Reject PRs that introduce per-iteration allocation in identified hot paths (tick loop, Channel ops, request routing) without an accompanying micro-benchmark proving necessity
- Reject PRs that downgrade `ArrayListUnmanaged` to `ArrayList`, or that introduce `std.io.Reader(T)`/`std.io.Writer(T)` generic factories (Zig 0.15 deprecated)
- Reject PRs that use `.seq_cst` memory ordering without justifying why `.acquire`/`.release` is insufficient
