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
        var it = self.tokens.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.name);
            self.allocator.free(entry.value_ptr.namespace);
        }
        self.tokens.deinit(self.allocator);
    }

    pub fn load(self: *TokenStore, tokens: []const Token) !void {
        // Validate entire slice before inserting anything to prevent partial state on error.
        for (tokens) |token| {
            if (token.namespace.len == 0) return TokenStoreError.EmptyNamespace;
        }
        for (tokens, 0..) |a, i| {
            for (tokens[0..i]) |b| {
                if (std.mem.eql(u8, a.secret, b.secret)) return TokenStoreError.DuplicateSecret;
            }
        }

        for (tokens) |token| {
            const secret_key = try self.allocator.dupe(u8, token.secret);

            const gop = self.tokens.getOrPut(self.allocator, secret_key) catch |err| {
                self.allocator.free(secret_key);
                return err;
            };

            const name_copy = self.allocator.dupe(u8, token.name) catch |err| {
                if (!gop.found_existing) self.tokens.removeByPtr(gop.key_ptr);
                self.allocator.free(secret_key);
                return err;
            };

            const ns_copy = self.allocator.dupe(u8, token.namespace) catch |err| {
                if (!gop.found_existing) self.tokens.removeByPtr(gop.key_ptr);
                self.allocator.free(secret_key);
                self.allocator.free(name_copy);
                return err;
            };

            if (gop.found_existing) {
                // Secret already present (e.g. calling load() again); free the duplicate key.
                self.allocator.free(secret_key);
            }

            gop.value_ptr.* = ClientIdentity{
                .name = name_copy,
                .namespace = ns_copy,
            };
        }
    }

    pub fn authenticate(self: *const TokenStore, secret: []const u8) ?ClientIdentity {
        var it = self.tokens.iterator();
        var result: ?ClientIdentity = null;
        while (it.next()) |entry| {
            if (domain.auth.constant_time_eql(entry.key_ptr.*, secret)) {
                result = entry.value_ptr.*;
            }
        }
        return result;
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
