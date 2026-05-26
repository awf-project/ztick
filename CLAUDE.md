## Architecture Rules

Stored in ZPM feedback segment. Query with: `zpm query-logic --goal "rule(Id, architecture, Desc, Prio, Src)" --memory feedback`

## Performance Principles

Stored in ZPM feedback segment. Query with: `zpm query-logic --goal "rule(Id, architecture, Desc, Prio, Src)" --memory feedback` (performance rules use `architecture` category with high priority for hot paths)

## Memory & Allocators

Stored in ZPM feedback segment. Query with: `zpm query-logic --goal "rule(Id, architecture, Desc, Prio, Src)" --memory feedback` (memory rules use `architecture` category)

## Concurrency

Stored in ZPM feedback segment. Query with: `zpm query-logic --goal "rule(Id, architecture, Desc, Prio, Src)" --memory feedback` (concurrency rules use `architecture` category)

## Protocol (TCP)

- Line-based text protocol over TCP; default listen 127.0.0.1:5678
- SET instruction: `SET <job_id> <timestamp_ns|YYYY-MM-DD HH:MM:SS>\n`; RULE SET: `RULE SET <rule_id> <pattern> <runner_type> [args...]\n`
- Responses: `<request_id> OK\n` or `<request_id> ERROR\n`
- Quoted strings supported: `"value with spaces"`, escapes `\"` and `\\`
- Timestamps: nanoseconds since Unix epoch (i64); datetime parsing supports years 1970+
- Parser uses ArrayListUnmanaged for tokens (protocol/parser.zig:34-43); single-pass tokenization with quote-aware splitter

## Protocol (HTTP)

- RESTful JSON API over HTTP/1.1; disabled by default, enabled via `[http] listen` in config
- Uses `std.http.Server` with the 0.16 Reader/Writer interface pattern: `stream.reader(&buf)` → `.interface()` passed to `http.Server.init`. Never parse HTTP manually
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

- **Zig 0.16.0 exact minimum** (build.zig.zon); no compatibility shims for older versions
- Minimal dependencies — zig-o11y/opentelemetry-sdk v0.2.0 for telemetry (ADR-0004), system OpenSSL via C bindings for TLS (ADR-0003), sam701/zig-cli (zig-0.16 branch) for argument parsing, stdlib for everything else
- `make build`, `make test`, `make lint` wrap zig build with `--summary all`
- Layer-specific test targets: `zig build test-domain`, `test-application`, `test-infrastructure`, `test-interfaces`, `test-functional`, `test-all`
- **Sanitizer test targets** (build.zig:161-206): `.sanitize_c = .full` (heap overflow detection) and `.sanitize_thread = true` (ThreadSanitizer for data races) on dedicated test binaries; run before any concurrency change
- Version single source of truth: `build.zig.zon` → `build_options` module → `version.zig` re-export → injected into OpenAPI spec at compile time
- TLS linking is conditional via build_root file probe; wraps `linkLibC()` + `linkSystemLibrary("ssl"/"crypto")` only when src/infrastructure/tls_context.zig exists

## Zig 0.16 Idioms

- **`std.Io` namespace for I/O**: Use `std.Io.Reader`, `std.Io.Writer`, `std.Io.File`, `std.Io.Dir` instead of the deprecated `std.io` and `std.fs` modules. Pass `io: std.Io` through context structs; cache `std.Io.Clock.Timestamp` on persistent state to avoid per-call clock construction (clock.zig:37-39 pattern)
- **Juicy Main pattern**: Replace `pub fn main() !void` with `pub fn main(init: std.process.Init) !void`; source the allocator, args, and I/O context from `init` rather than manual allocation. Route `init.minimal.args` through application code (cli.zig:97-99 pattern)
- **`@EnumLiteral` builtin**: Use `@EnumLiteral` instead of deprecated `@Type(.enum_literal)` for creating enum literals at comptime (main.zig:68)
- **`std.Io.Reader.fixed` / `std.Io.Writer.fixed`**: Replace `std.io.fixedBufferStream` (fully removed in 0.16) with fixed-size Reader/Writer pairs. Call `.interface()` to expose the Reader/Writer interface to consumers (resp.zig test pattern)
- **Reader/Writer interface pattern**: use `stream.reader(&buf)` then `.interface()` for `std.http.Server` and friends; the interface stays consistent across 0.16
- **`std.mem.splitScalar(u8, input, '\n')`** for single-byte delimiters; `splitSequence` for multi-byte
- **`std.AutoHashMapUnmanaged(K, V)`** for integer/struct keys, **`std.StringHashMapUnmanaged(V)`** for `[]const u8` keys; both prefer Unmanaged variants
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

- OpenTelemetry via zig-o11y/opentelemetry-sdk v0.2.0; instruments live in application/instruments.zig and are optional (telemetry disabled = `?Instruments` is null)
- Hot paths annotate spans with `setAttribute` only inside `if (instruments)` guards; never compute attributes when instruments is null
- Custom OTLP exporter (telemetry.zig:57-224) injects resource attributes into ResourceSpans because the SDK doesn't propagate them; uses comptime reflection to avoid boilerplate field accessors
- Counters/gauges: `jobs_scheduled`, `jobs_removed`, `rules_active`, `execution_duration_ms` (histogram)

## Common Pitfalls

Stored in ZPM feedback segment. Query with: `zpm query-logic --goal "rule(Id, pitfall, Desc, Prio, Src)" --memory feedback`

## Test Conventions

Stored in ZPM feedback segment. Query with: `zpm query-logic --goal "rule(Id, test, Desc, Prio, Src)" --memory feedback`

## Review Standards

Stored in ZPM feedback segment. Query with: `zpm query-logic --goal "rule(Id, review, Desc, Prio, Src)" --memory feedback`

## ZPM Project Memory

This project uses ZPM memory segments as its knowledge base. **Query ZPM before starting work. Update ZPM as you learn.**

### Segments

| Segment | Purpose | Mount |
|---------|---------|-------|
| `default` | Project knowledge: ADRs, decisions, observations, conventions, architecture facts | auto |
| `feedback` | Learned rules from past implementations/reviews — queryable by file pattern | auto |
| `pr_<branch>` | PR tracking: TODOs, stubs, mocks, blocking issues, completion gate | per-implementation |

### PR tracking — during implementation

```bash
# Query unresolved issues (derived predicates)
zpm query-logic --goal "unresolved_todo(Id, File, Line, Desc)" --memory pr_<branch>
zpm query-logic --goal "unresolved_stub(Id, File, Symbol)" --memory pr_<branch>
zpm query-logic --goal "unresolved_mock(Id, File, Symbol)" --memory pr_<branch>
zpm query-logic --goal "unresolved_not_impl(Id, File, Desc)" --memory pr_<branch>

# Mark issues resolved
zpm remember-fact --fact "resolved(todo, Id)" --memory pr_<branch>
zpm remember-fact --fact "resolved(stub, Id)" --memory pr_<branch>

# Check PR readiness
zpm query-logic --goal "pr_ready" --memory pr_<branch>
zpm query-logic --goal "blocking_issue(Id, Type, File, Desc)" --memory pr_<branch>
```

### Read before acting

```bash
# What decisions exist about this area?
zpm query-logic --goal "decision(Id, What, Why)" --memory default
# What feedback rules apply to files I'm touching?
zpm query-logic --goal "rule(Id, Cat, Desc, Prio, Src)" --memory feedback
# What rules apply specifically to a file/directory?
zpm query-logic --goal "applicable(RuleId, 'src/path/file.ext')" --memory feedback
# What ADRs are active?
zpm query-logic --goal "current_decision(Id, Decision)" --memory default
# Any architecture violations?
zpm query-logic --goal "integrity_violation(Kind, File)" --memory default
```

### Write as you work

```bash
# Observation: discovered something non-obvious
zpm remember-fact --fact "observation(id, Category, 'Description', 'YYYY-MM-DD')" --memory default
# Categories: pattern | convention | quirk | dependency | performance

# Decision: made an architectural choice
zpm remember-fact --fact "decision(id, 'What', 'Why', 'Trade-off')" --memory default

# Feedback rule: a mistake teaches a reusable lesson
zpm remember-fact --fact "rule(rule_id, Category, 'Imperative rule', Priority, Source)" --memory feedback
zpm remember-fact --fact "trigger(rule_id, 'pattern', Scope)" --memory feedback
# Categories: architecture | pitfall | test | review | style
# Priority: high | medium | low — Scope: file | directory | project
```

### What NOT to store

- File contents, git status, directory listings — ephemeral
- Anything already in code comments or documentation
- Duplicate of an existing fact — query first

### Architecture Rules

Query: `zpm query-logic --goal "rule(Id, architecture, Desc, Prio, Src)" --memory feedback`

### Test Conventions

Query: `zpm query-logic --goal "rule(Id, test, Desc, Prio, Src)" --memory feedback`

### Common Pitfalls

Query: `zpm query-logic --goal "rule(Id, pitfall, Desc, Prio, Src)" --memory feedback`

### Review Standards

Query: `zpm query-logic --goal "rule(Id, review, Desc, Prio, Src)" --memory feedback`
