## Architecture Rules

- Use hexagonal layering: domain (entities), application (use cases), infrastructure (adapters). Organize modules with barrel exports
- Use tagged unions for protocol and runner types; error unions for fallible operations
- Four strict layers: domain/ (pure data, zero deps), application/ (state machines, storage), infrastructure/ (IO adapters), interfaces/ (CLI, config)
- Each layer has a barrel export file (domain.zig, application.zig, infrastructure.zig, interfaces.zig); import layers through barrels only
- All tagged union variants must declare payloads with `struct {}` syntax, even when empty, for consistent pattern matching and destructuring across the codebase
- Logfile dump must never load entire file into memory; implement sequential frame reads to comply with NFR-001 scaling constraint
- Use Process.execute() for all background operations; never manually construct Process structs in application layer to maintain API consistency

## Build System

- Zig 0.15.2; minimal dependencies — zig-o11y/opentelemetry-sdk for telemetry (ADR-0004), system OpenSSL for TLS (ADR-0003), stdlib for everything else
- `make build`, `make test`, `make lint` wrap zig build with `--summary all`
- Layer-specific test targets: `zig build test-domain`, `test-application`, `test-infrastructure`, `test-interfaces`, `test-functional`, `test-all`

## Naming Conventions

- Types: PascalCase (Job, ShellRunner, ParseResult). Functions: snake_case (handle_query, encode_job). Constants: snake_case (max_entry_size)
- Error types suffixed with Error (ConfigError, SendError, ParseError, DecodeError)
- Abbreviations: ch (channel), req/resp (request/response), instr (instruction), id (identifier), ns (nanoseconds)

## Concurrency

- Three-thread architecture: controller (TCP server), database (scheduler tick loop), processor (job executor)
- Bounded FIFO channels (Channel(T)) with mutex + condition variables for inter-thread communication; capacity 64
- Atomic flag (std.atomic.Value(bool)) for cross-thread shutdown coordination
- Per-connection ResponseRouter with mutex-guarded AutoHashMap; each TCP connection registers its own response channel
- Shutdown order: join controller → store false to running → close request channel → join database → close exec channel → join processor

## Protocol (TCP)

- Line-based text protocol over TCP; default listen 127.0.0.1:5678
- SET instruction: `SET <job_id> <timestamp_ns|YYYY-MM-DD HH:MM:SS>\n`; RULE SET: `RULE SET <rule_id> <pattern> <runner_type> [args...]\n`
- Responses: `<request_id> OK\n` or `<request_id> ERROR\n`
- Quoted strings supported: `"value with spaces"`, escapes `\"` and `\\`
- Timestamps: nanoseconds since Unix epoch (i64); datetime parsing supports years 1970+

## Persistence

- Append-only logfile with 4-byte big-endian length-prefixed framing per entry
- Binary encoding: type byte + u16 length-prefixed strings + i64 timestamps + u8 status
- Compression: deduplicate by ID → write to .tmp → atomic rename to .compressed → delete source
- On load: read entire file, parse frames, decode entries into arena allocator (arena kept for lifetime)

## Configuration

- Custom TOML parser; sections: [log] (level), [controller] (listen), [database] (fsync_on_persist, framerate, logfile_path)
- CLI flag: `-c`/`--config` for config path; defaults applied when file missing; max file size 1MB
- Framerate range: 1-65535 (u16); log levels: off, error, warn, info, debug, trace

## Common Pitfalls

- Always use errdefer for cleanup on error paths; free allocations in reverse acquisition order
- Join all spawned threads in main() and block until exit; defer deinit channels for resource cleanup
- Pass allocator as parameter to allocation functions; never use cwd() directly in background operations
- Use atomic rename pattern for persistence writes; verify file operations before committing state
- Use per-connection response channels; never share a response channel across concurrent connections
- Propagate allocation errors immediately; never catch OOM and convert to false success
- Copy storage results into owned allocation before mutation; never iterate and mutate simultaneously
- Close channels before joining threads to prevent deadlocks; document shutdown sequence explicitly
- Try openFile(.write_only) first, fall back to createFile for new logfiles; handles both append and initialization
- Pre-allocate capacity in thread tracking list before spawning; ensure append cannot fail due to OOM and orphan spawned threads
- Remove thread handles from tracking list after joining; never accumulate handles indefinitely as this causes O(n) memory growth
- Always escape control characters (0x00-0x1F excluding tab/CR/LF) in JSON output per RFC 8259; missing escapes produce invalid JSON that tools like jq reject
- For follow mode initial offset: subtract remaining partial-frame bytes from file length, not file length itself; starting at file end skips incomplete frames
- Never silently ignore persistence decode errors; emit warnings to stderr with byte offset for each failure to aid debugging

- When copying structs containing ArrayListUnmanaged or similar shared-backing types, ensure only the owning copy calls deinit; non-owning copies must be dropped without cleanup to prevent double-frees

- Retain .to_compress file on failed atomic rename during compression; verify destination non-existence before overwrite to prevent silent data loss during file rotation

- Use monotonic time or atomic counters for compression intervals; avoid wall-clock subtraction which wraps on NTP stepback causing infinite compression loops

- Add generated compression artifacts (.compressed, .to_compress) to .gitignore; never stage test output files or temporary persistence artifacts

- Always log failed background compression at ERROR level with .to_compress file path; retention of orphaned compression files is required for data recovery

## Test Conventions

- Co-locate unit tests in test blocks within source files; use functional_tests.zig for integration tests
- Verbose test names describe behavior (e.g., `test "tick processes query request and routes response"`)

- Always use std.testing.tmpDir for test files; never hardcode /tmp paths which create race conditions across parallel test execution

## Review Standards

- Normalize all function names to snake_case, including private functions; remove dead code completely
- Verify implementation matches the original specification (e.g., protocol format, timestamp parsing, command definitions)
- Never name tests after implementation internals (e.g., 'has no payload'); name them after observable behavior from the caller's perspective (e.g., 'returns formatted rules')
