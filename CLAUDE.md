## Architecture Rules

- Use hexagonal layering: domain (entities), application (use cases), infrastructure (adapters). Organize modules with barrel exports
- Use tagged unions for protocol and runner types; error unions for fallible operations
- Four strict layers: domain/ (pure data, zero deps), application/ (state machines, storage), infrastructure/ (IO adapters), interfaces/ (CLI, config)
- Each layer has a barrel export file (domain.zig, application.zig, infrastructure.zig, interfaces.zig); import layers through barrels only
- All tagged union variants must declare payloads with `struct {}` syntax, even when empty, for consistent pattern matching and destructuring across the codebase
- Logfile dump must never load entire file into memory; implement sequential frame reads to comply with NFR-001 scaling constraint
- Use Process.execute() for all background operations; never manually construct Process structs in application layer to maintain API consistency

- Send ERROR response for all protocol validation failures before disconnecting; never silently close connections on parse errors like RULE SET with missing executable

- Authenticated HTTP endpoints must explicitly include 401 Unauthorized response schemas in OpenAPI specs; inherited security definitions don't auto-document client error handling paths

- Maintain CRUD endpoint parity in OpenAPI specs; if GET /jobs/{id} exists, corresponding GET /rules/{id} must exist or be explicitly documented as omitted in spec comments

- Implement configuration parsing for new subsystems before wiring them as application threads; verify [http], [controller], [database] sections exist in config.zig before feature completion

## Build System

- Zig 0.15.2; minimal dependencies — zig-o11y/opentelemetry-sdk for telemetry (ADR-0004), system OpenSSL for TLS (ADR-0003), stdlib for everything else
- `make build`, `make test`, `make lint` wrap zig build with `--summary all`
- Layer-specific test targets: `zig build test-domain`, `test-application`, `test-infrastructure`, `test-interfaces`, `test-functional`, `test-all`

## Naming Conventions

- Types: PascalCase (Job, ShellRunner, ParseResult). Functions: snake_case (handle_query, encode_job). Constants: snake_case (max_entry_size)
- Error types suffixed with Error (ConfigError, SendError, ParseError, DecodeError)
- Abbreviations: ch (channel), req/resp (request/response), instr (instruction), id (identifier), ns (nanoseconds)

## Concurrency

- Four-thread architecture: controller (TCP server), database (scheduler tick loop), processor (job executor), http (REST API — optional, enabled via [http] config section)
- Bounded FIFO channels (Channel(T)) with mutex + condition variables for inter-thread communication; capacity 64
- Atomic flag (std.atomic.Value(bool)) for cross-thread shutdown coordination
- Per-connection ResponseRouter with mutex-guarded AutoHashMap; each TCP connection registers its own response channel
- Shutdown order: join controller → join http (if enabled) → store false to running → close request channel → join database → close exec channel → join processor

## Protocol (TCP)

- Line-based text protocol over TCP; default listen 127.0.0.1:5678
- SET instruction: `SET <job_id> <timestamp_ns|YYYY-MM-DD HH:MM:SS>\n`; RULE SET: `RULE SET <rule_id> <pattern> <runner_type> [args...]\n`
- Responses: `<request_id> OK\n` or `<request_id> ERROR\n`
- Quoted strings supported: `"value with spaces"`, escapes `\"` and `\\`
- Timestamps: nanoseconds since Unix epoch (i64); datetime parsing supports years 1970+

## Protocol (HTTP)

- RESTful JSON API over HTTP/1.1; disabled by default, enabled via `[http] listen` in config
- Uses std.http.Server for parsing/responses; OpenAPI 3.1.1 spec embedded via @embedFile (symlink from src/infrastructure/ to root openapi.json)
- Endpoints: GET/PUT/DELETE /jobs/{id}, GET /jobs?prefix=, GET/PUT/DELETE /rules/{id}, GET /rules?prefix=, GET /health, GET /openapi.json
- DELETE returns 204 No Content; PUT/GET return 200 with JSON body; errors return 400/401/404/405/413 with `{"error":"message"}`
- Optional Bearer token authentication; /health and /openapi.json are public (no auth required)
- HTTP thread shares Channel(query.Request) and ResponseRouter with TCP controller and database threads

## Persistence

- Append-only logfile with 4-byte big-endian length-prefixed framing per entry
- Binary encoding: type byte + u16 length-prefixed strings + i64 timestamps + u8 status
- Compression: deduplicate by ID → write to .tmp → atomic rename to .compressed → delete source
- On load: read entire file, parse frames, decode entries into arena allocator (arena kept for lifetime)

## Configuration

- Custom TOML parser; sections: [log] (level), [controller] (listen), [database] (fsync_on_persist, framerate, logfile_path), [http] (listen), [telemetry], [shell]
- CLI flag: `-c`/`--config` for config path; defaults applied when file missing; max file size 1MB
- Framerate range: 1-65535 (u16); log levels: off, error, warn, info, debug, trace
- HTTP server disabled by default; enabled only when [http] section with listen key is present

## Common Pitfalls

- Use per-connection response channels; never share a response channel across concurrent connections
- Propagate allocation errors immediately; never catch OOM and convert to false success
- Copy storage results into owned allocation before mutation; never iterate and mutate simultaneously
- Close channels before joining threads to prevent deadlocks; document shutdown sequence explicitly
- Try openFile(.write_only) first, fall back to createFile for new logfiles; handles both append and initialization
- Pre-allocate capacity in thread tracking list before spawning; ensure append cannot fail due to OOM and orphan spawned threads
- Remove thread handles from tracking list after joining; never accumulate handles indefinitely as this causes O(n) memory growth
- Use std.json.Stringify for all JSON serialization; never build JSON strings manually. Use std.json.parseFromSlice for deserialization into typed structs
- For follow mode initial offset: subtract remaining partial-frame bytes from file length, not file length itself; starting at file end skips incomplete frames
- Never silently ignore persistence decode errors; emit warnings to stderr with byte offset for each failure to aid debugging

- When copying structs containing ArrayListUnmanaged or similar shared-backing types, ensure only the owning copy calls deinit; non-owning copies must be dropped without cleanup to prevent double-frees

- Retain .to_compress file on failed atomic rename during compression; verify destination non-existence before overwrite to prevent silent data loss during file rotation

- Use monotonic time or atomic counters for compression intervals; avoid wall-clock subtraction which wraps on NTP stepback causing infinite compression loops

- Add generated compression artifacts (.compressed, .to_compress) to .gitignore; never stage test output files or temporary persistence artifacts

- Always log failed background compression at ERROR level with .to_compress file path; retention of orphaned compression files is required for data recovery

- Always validate shell executables with execute mode (.{ .mode = .execute }), not default read-only mode; default mode misses executable permission failures that fail at runtime

- Always unescape TOML escape sequences when parsing array values; skipping escape bytes and copying raw backslashes produces literal backslashes instead of unescaped values

- Never duplicate specification details across files (openapi.yaml, http-api.md, types.md); maintain single source of truth per spec element (schema descriptions, format rules, field definitions)

- Never commit stub barrel files without implementation; add `@compileError` to unimplemented public functions to prevent partial feature merges

- Add all compiled binaries and build artifacts (test_zig, *.o, *.a, *.so) to .gitignore; build outputs must never be staged or committed

## Test Conventions

- Co-locate unit tests in test blocks within source files; use functional_tests.zig for integration tests
- Verbose test names describe behavior (e.g., `test "tick processes query request and routes response"`)

- Always use std.testing.tmpDir for test files; never hardcode /tmp paths which create race conditions across parallel test execution

- Always verify unit tests execute through `zig build test-<layer>` targets, not just direct `zig test`; barrel export chains may prevent test discovery by the build system

## Review Standards

- Normalize all function names to snake_case, including private functions; remove dead code completely
- Verify implementation matches the original specification (e.g., protocol format, timestamp parsing, command definitions)
- Never name tests after implementation internals (e.g., 'has no payload'); name them after observable behavior from the caller's perspective (e.g., 'returns formatted rules')
- HTTP DELETE operations must return 204 No Content for successful deletions; return 200 only when response body is present (violates client expectations)
- Verify all planned components are implemented before merge; HTTP controller requires std.http.Server routing, json codec (std.json), [http] config section, and threading — all must compile and pass tests
- Use std.http.Server for HTTP request/response handling; never parse HTTP manually. Use request.respond() for responses, iterateHeaders() for custom headers
- Dupe all instruction string identifiers before sending to scheduler via Channel; scheduler stores pointers without copying (same ownership pattern as TCP server's build_instruction)
