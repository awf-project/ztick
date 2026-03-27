## Architecture Rules

- Use hexagonal layering: domain (entities), application (use cases), infrastructure (adapters). Organize modules with barrel exports
- Use tagged unions for protocol and runner types; error unions for fallible operations
- Four strict layers: domain/ (pure data, zero deps), application/ (state machines, storage), infrastructure/ (IO adapters), interfaces/ (CLI, config)
- Each layer has a barrel export file (domain.zig, application.zig, infrastructure.zig, interfaces.zig); import layers through barrels only

## Build System

- Zig 0.14.0+ required; zero external dependencies (stdlib only); build.zig.zon `dependencies = .{}`
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

## Test Conventions

- Co-locate unit tests in test blocks within source files; use functional_tests.zig for integration tests
- Verbose test names describe behavior (e.g., `test "tick processes query request and routes response"`)

## Review Standards

- Normalize all function names to snake_case, including private functions; remove dead code completely
- Verify implementation matches the original specification (e.g., protocol format, timestamp parsing, command definitions)
