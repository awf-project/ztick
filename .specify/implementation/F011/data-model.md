# Data Model: F011 - Client Authentication

## Entities

### Token

Credential loaded from auth file at startup. Read-only after initialization.

```zig
pub const Token = struct {
    name: []const u8,      // e.g., "deploy_service"
    secret: []const u8,    // e.g., "sk_deploy_a1b2c3d4e5f6"
    namespace: []const u8, // e.g., "deploy." or "*"
};
```

**Location**: `src/domain/auth.zig`
**Lifecycle**: Allocated during auth file parsing, owned by TokenStore, freed on TokenStore.deinit()
**Invariants**:
- `secret` must be non-empty
- `namespace` must be non-empty
- `namespace` must end with `.` or be exactly `"*"`
- No two tokens may share the same `secret` value

### ClientIdentity

Resolved identity for an authenticated connection. Secret-free per FR-011.

```zig
pub const ClientIdentity = struct {
    name: []const u8,      // borrowed from Token
    namespace: []const u8, // borrowed from Token
};
```

**Location**: `src/domain/auth.zig`
**Lifecycle**: Created by `TokenStore.authenticate()`, lives as a stack-local in `handle_connection()`, references Token memory owned by TokenStore (valid for server lifetime)
**Invariants**:
- Never contains the secret
- `namespace` follows same rules as Token.namespace

### TokenStore

Application service managing token lookup and authorization.

```zig
pub const TokenStore = struct {
    allocator: std.mem.Allocator,
    secrets: std.StringHashMapUnmanaged(ClientIdentity),
    // Key: secret string, Value: ClientIdentity (name + namespace)
};
```

**Location**: `src/application/token_store.zig`
**Lifecycle**: Created in `main()` after config load, passed to ControllerContext, lives for server lifetime
**Methods**:
- `init(allocator, tokens: []const Token) !TokenStore` — validates no duplicate secrets, builds hashmap
- `deinit(*TokenStore) void` — frees hashmap
- `authenticate(secret: []const u8) ?ClientIdentity` — constant-time lookup
- `is_authorized(identity: ClientIdentity, identifier: []const u8) bool` — prefix check

## Auth File Format

```toml
[token.deploy_service]
secret = "sk_deploy_a1b2c3d4e5f6"
namespace = "deploy."

[token.admin]
secret = "sk_admin_x9y8z7w6v5u4"
namespace = "*"
```

**Parser location**: `src/infrastructure/auth.zig`
**Section pattern**: `[token.<name>]` — name extracted from section header
**Required keys**: `secret`, `namespace`
**Validation**: duplicate secrets rejected, empty namespaces rejected, missing keys rejected

## Relationships

```
Auth File (TOML) --parsed by--> auth.zig (infrastructure)
    |
    v
Token[] --loaded into--> TokenStore (application)
    |
    v
TokenStore.authenticate(secret) --> ?ClientIdentity
    |
    v
ClientIdentity --used in--> handle_connection (infrastructure)
    |                             |
    v                             v
is_authorized(identity, id)   namespace filtering on QUERY
```

## Config Extension

```zig
// In Config struct (src/interfaces/config.zig)
controller_auth_file: ?[]const u8,  // null = no auth (backward compat)
```

Parsed in `[controller]` section alongside `listen`, `tls_cert`, `tls_key`.
