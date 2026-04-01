# F001: Add GET command to ztick protocol

## Description

The `GET <id>` command is documented in `docs/reference/protocol.md` and referenced in user guides, but the server silently ignores it. A user sending `GET my.job` receives no response because `build_instruction()` in `tcp_server.zig` returns `null` — the `Instruction` type has no `get` variant.

The storage layer already supports retrieval via `JobStorage.get()`, which returns `?Job` by identifier. The missing piece is wiring the protocol command through the instruction → query handler → response chain, including enriching the response format to carry job state data (status, execution timestamp).

## Tasks

- [ ] Add `get` variant to `Instruction` tagged union in `src/domain/instruction.zig`
- [ ] Extend `query.Response` in `src/domain/query.zig` with an optional `body: ?[]const u8` field for data-carrying responses
- [ ] Handle `get` instruction in `QueryHandler.handle()` in `src/application/query_handler.zig` — call `job_storage.get()`, format status and execution timestamp into response body, return failure if job not found
- [ ] Parse `GET` command in `build_instruction()` in `src/infrastructure/tcp_server.zig` — match `args[0] == "GET"` with `args.len >= 2`
- [ ] Add `get` arms to `is_borrowed_by_instruction()` and `free_instruction_strings()` in `tcp_server.zig`
- [ ] Update `write_response()` in `tcp_server.zig` to append body content after `OK` when `response.body` is non-null
- [ ] Handle or explicitly skip `get` variant in `src/infrastructure/persistence/encoder.zig` — GET is read-only, must not generate a persistence log entry
- [ ] Add unit test: GET existing job returns success with status and execution timestamp
- [ ] Add unit test: GET missing job returns failure
- [ ] Add functional test in `functional_tests.zig`: SET then GET round-trip verifying response format `<request_id> OK <status> <execution_ns>
`

## Impact

- **Files affected**: `src/domain/instruction.zig`, `src/domain/query.zig`, `src/application/query_handler.zig`, `src/infrastructure/tcp_server.zig`, `src/infrastructure/persistence/encoder.zig`, `src/functional_tests.zig`
- **Breaking changes**: no
- **Downtime required**: no

## Acceptance Criteria

- [ ] `GET <id>` for an existing job returns `<request_id> OK <status> <execution_ns>
` with correct status (`planned`, `triggered`, `executed`, `failed`) and execution nanosecond timestamp
- [ ] `GET <id>` for a nonexistent job returns `<request_id> ERROR
`
- [ ] GET does not produce any persistence log entry
- [ ] All existing tests continue to pass — no regressions in SET, RULE SET, or response routing
- [ ] Response body memory is freed by the TCP server after writing to the client
- [ ] `zig build test-all` passes with new GET tests included

---

## Metadata

- **Status**: backlog
- **Version**: v0.1.0
- **Priority**: high
- **Estimation**: M

## Related

- **Blocks**: none
- **Related issues**: none

## Notes

_The main design decision is enriching `Response` with an optional `body: ?[]const u8` rather than introducing a separate response type. This keeps the existing request/response channel generic and avoids a second channel or tagged union at the transport layer. The query handler allocates the formatted body string, and the TCP server frees it after writing — ownership transfers across the channel boundary. This pattern will also serve QUERY and future read commands that return data._
