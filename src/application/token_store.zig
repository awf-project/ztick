const std = @import("std");
const domain = @import("../domain.zig");

const Token = domain.auth.Token;
const ClientIdentity = domain.auth.ClientIdentity;

pub const TokenStoreError = error{
    DuplicateSecret,
    EmptyNamespace,
};

pub const TokenStore = struct {
    allocator: std.mem.Allocator,
    tokens: std.StringHashMapUnmanaged(ClientIdentity),

    pub fn init(allocator: std.mem.Allocator) TokenStore {
        return .{
            .allocator = allocator,
            .tokens = .{},
        };
    }

    pub fn deinit(self: *TokenStore) void {
        self.tokens.deinit(self.allocator);
    }

    pub fn load(self: *TokenStore, tokens: []const Token) !void {
        for (tokens) |token| {
            if (token.namespace.len == 0) return TokenStoreError.EmptyNamespace;
            const gop = try self.tokens.getOrPut(self.allocator, token.secret);
            if (gop.found_existing) return TokenStoreError.DuplicateSecret;
            gop.value_ptr.* = ClientIdentity{
                .name = token.name,
                .namespace = token.namespace,
            };
        }
    }

    pub fn authenticate(self: *const TokenStore, secret: []const u8) ?ClientIdentity {
        return self.tokens.get(secret);
    }

    pub fn is_authorized(identity: ClientIdentity, identifier: []const u8) bool {
        if (std.mem.eql(u8, identity.namespace, "*")) return true;
        return std.mem.startsWith(u8, identifier, identity.namespace);
    }
};

test "authenticate returns identity for valid secret" {
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    const tokens = [_]Token{
        .{ .name = "deploy", .secret = "sk_abc123", .namespace = "deploy." },
    };
    try store.load(&tokens);
    const identity = store.authenticate("sk_abc123");
    try std.testing.expect(identity != null);
    try std.testing.expectEqualStrings("deploy", identity.?.name);
    try std.testing.expectEqualStrings("deploy.", identity.?.namespace);
}

test "authenticate returns null for unknown secret" {
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    const tokens = [_]Token{
        .{ .name = "deploy", .secret = "sk_abc123", .namespace = "deploy." },
    };
    try store.load(&tokens);
    const identity = store.authenticate("sk_wrong");
    try std.testing.expect(identity == null);
}

test "load rejects duplicate secrets" {
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    const tokens = [_]Token{
        .{ .name = "deploy", .secret = "sk_shared", .namespace = "deploy." },
        .{ .name = "backup", .secret = "sk_shared", .namespace = "backup." },
    };
    try std.testing.expectError(TokenStoreError.DuplicateSecret, store.load(&tokens));
}

test "load rejects empty namespace" {
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    const tokens = [_]Token{
        .{ .name = "deploy", .secret = "sk_abc123", .namespace = "" },
    };
    try std.testing.expectError(TokenStoreError.EmptyNamespace, store.load(&tokens));
}

test "is_authorized allows matching namespace prefix" {
    const identity = ClientIdentity{ .name = "deploy", .namespace = "deploy." };
    try std.testing.expect(TokenStore.is_authorized(identity, "deploy.release.1"));
}

test "is_authorized denies non-matching namespace prefix" {
    const identity = ClientIdentity{ .name = "deploy", .namespace = "deploy." };
    try std.testing.expect(!TokenStore.is_authorized(identity, "backup.daily"));
}

test "is_authorized wildcard namespace allows any identifier" {
    const identity = ClientIdentity{ .name = "admin", .namespace = "*" };
    try std.testing.expect(TokenStore.is_authorized(identity, "anything.goes"));
}
