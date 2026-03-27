# Persistence Format

Specification of ztick's binary persistence format used for logfiles.

## Overview

ztick persists jobs and rules to a binary logfile, enabling recovery after restarts. The format is designed for:

- **Performance**: Efficient parsing and writing
- **Durability**: Each entry has length prefix for robustness
- **Simplicity**: No external serialization library needed

## File Structure

A logfile is a sequence of **entries**, each prefixed with its length:

```
[Entry 1]
[Entry 2]
...
[Entry N]
```

No file header or magic bytes — the logfile is a raw sequence of length-prefixed entries.

### Entry Format

```
[4 bytes: entry length (big-endian u32)]
[1 byte: entry type discriminant]
[N bytes: entry-specific data]
```

The entry type discriminant determines how to interpret the remaining bytes.

## Entry Types

### Type 0: Job Entry

Stores a single job record.

```
[1 byte: type = 0]
[2 bytes: identifier length (big-endian u16)]
[L bytes: identifier string (UTF-8)]
[8 bytes: execution timestamp (big-endian i64, nanoseconds)]
[1 byte: status (0=planned, 1=triggered, 2=executed, 3=failed)]
```

**Example** (hex dump for job "toto", timestamp 2020-11-15T16:30:00Z, status planned):

```
00000000: 00 00 00 10 00 00 04 74 6f 74 6f 16 47 bb 5c ee  .......toto.G.\.
00000010: e1 50 00 00                                       .P..
```

Breakdown:
- `00000010` = length 16 bytes
- `00` = type 0 (Job)
- `0004` = identifier length 4
- `746f746f` = "toto" (UTF-8)
- `1647bb5ceee15000` = timestamp 1605457800000000000 ns
- `00` = status planned

### Type 1: Rule Entry

Stores a single rule record with its runner.

```
[1 byte: type = 1]
[2 bytes: identifier length (big-endian u16)]
[L bytes: identifier string (UTF-8)]
[2 bytes: pattern length (big-endian u16)]
[L bytes: pattern string (UTF-8)]
[1 byte: runner type (0=shell, 1=amqp)]
  ├─ if runner_type == 0 (shell):
  │  [2 bytes: command length (big-endian u16)]
  │  [L bytes: command string (UTF-8)]
  └─ if runner_type == 1 (amqp):
     [2 bytes: dsn length (big-endian u16)]
     [L bytes: dsn string (UTF-8)]
     [2 bytes: exchange length (big-endian u16)]
     [L bytes: exchange string (UTF-8)]
     [2 bytes: routing_key length (big-endian u16)]
     [L bytes: routing_key string (UTF-8)]
```

**Example** (shell runner for rule "t" matching pattern "toto" with command "titi"):

```
00000000: 00 00 00 11 01 00 01 74 00 04 74 6f 74 6f 00 00  .......t..toto..
00000010: 04 74 69 74 69                                    .titi
```

Breakdown:
- `00000011` = length 17 bytes
- `01` = type 1 (Rule)
- `0001` = identifier length 1
- `74` = "t" (UTF-8)
- `0004` = pattern length 4
- `746f746f` = "toto" (UTF-8)
- `00` = runner type 0 (shell)
- `0004` = command length 4
- `74697469` = "titi" (UTF-8)

## Encoding Details

### String Encoding

All strings are UTF-8 encoded with a 2-byte big-endian length prefix:

```zig
[2 bytes: string length (big-endian u16)]
[L bytes: UTF-8 string data]
```

Maximum string length: 65535 bytes (2^16 - 1). The encoder returns `error.Overflow` if a string exceeds this limit.

### Timestamp Encoding

Execution timestamps are stored as big-endian i64 in **nanoseconds** since Unix epoch:

```
1711612800000000000 ns = 2024-03-28 12:00:00 UTC
```

To convert from seconds:
```zig
const seconds = 1711612800;
const nanoseconds = seconds * 1_000_000_000;  // 1711612800000000000
```

### Status Encoding

Job status is stored as a single byte:

| Value | Status |
|-------|--------|
| 0 | planned |
| 1 | triggered |
| 2 | executed |
| 3 | failed |

### Runner Type Encoding

Runner type is stored as a single byte:

| Value | Type |
|-------|------|
| 0 | shell |
| 1 | amqp |

## Writing Entries

When persisting a job or rule:

1. Serialize the entry to a buffer
2. Calculate the entry length (without the 4-byte length prefix)
3. Write the 4-byte length prefix (big-endian)
4. Write the entry data
5. Optionally fsync to ensure durability

**Example** (writing a job):

```zig
var buffer = try allocator.alloc(u8, 1024);
var offset: usize = 0;

// Skip length field (will fill later)
offset += 4;

// Write type
buffer[offset] = 0;  // Job
offset += 1;

// Write identifier
const id_bytes = job.identifier;
std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(id_bytes.len), .big);
offset += 2;
@memcpy(buffer[offset .. offset + id_bytes.len], id_bytes);
offset += id_bytes.len;

// Write execution timestamp
std.mem.writeInt(i64, buffer[offset..][0..8], job.execution, .big);
offset += 8;

// Write status
buffer[offset] = @intFromEnum(job.status);
offset += 1;

// Fill in the length field
const entry_length = offset - 4;
std.mem.writeInt(u32, buffer[0..4], @intCast(entry_length), .big);

// Write to file
try file.writeAll(buffer[0..offset]);
```

## Reading Entries

When reading a logfile:

1. Read 4-byte length prefix
2. Allocate buffer of that size
3. Read the entry data
4. Parse based on type byte
5. Return the deserialized entry

**Example** (reading entries):

```zig
while (true) {
    var length_bytes: [4]u8 = undefined;
    const read = try file.read(&length_bytes);
    if (read == 0) break;  // EOF

    const entry_length = std.mem.readInt(u32, &length_bytes, .big);
    var entry_data = try allocator.alloc(u8, entry_length);

    try file.readAll(entry_data);

    const entry_type = entry_data[0];
    switch (entry_type) {
        0 => {
            // Parse Job
        },
        1 => {
            // Parse Rule
        },
        else => return error.UnknownEntryType,
    }
}
```

## Error Handling

### Incomplete Entry

If the file ends mid-entry:

```zig
return error.IncompleteEntry
```

Example: 4-byte length prefix present but not enough data for the entry.

### Invalid Type

If the type byte is unknown:

```zig
return error.UnknownEntryType
```

### Malformed String

If a string length exceeds the remaining buffer:

```zig
return error.StringOverflow
```

## Recovery

On startup, ztick reads the entire logfile:

1. Parse the raw bytes into length-prefixed frames
2. Decode each frame into a Job or Rule entry
3. Load Job entries into `JobStorage`, Rule entries into `RuleStorage`

If a frame is incomplete (e.g., truncated write from a crash), the parser stops and returns the remaining unparsed bytes — it does not skip ahead. If a complete frame contains invalid data, decoding returns `InvalidData` and loading stops. This means corruption at any point truncates the log at that position; entries after the corruption are lost.

## Performance Characteristics

- **Write latency**: ~1-10 us per entry (buffered)
- **Read latency**: ~1-10 us per entry (sequential scan)
- **Durability**: With fsync enabled, guaranteed to disk after each write
- **Compression**: Background process can compress old logfiles

## Logfile Size

Typical entry sizes:

| Entry Type | Typical Size |
|------------|------------|
| Job (short id) | 30-50 bytes |
| Job (long id) | 50-100 bytes |
| Rule (short pattern, short command) | 40-60 bytes |
| Rule (long pattern, long command) | 100-200 bytes |

With 10,000 jobs and 100 rules, expect ~300 KB logfile.

## See Also

- **[Data Types](types.md)** — Structure of Job and Rule types
- **[Configuration](configuration.md)** — fsync_on_persist and framerate settings
- **[Reference](README.md)** — Overview of all reference docs
