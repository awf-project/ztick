const std = @import("std");

pub const Token = struct {
    name: []const u8,
    secret: []const u8,
    namespace: []const u8,
};

pub const ClientIdentity = struct {
    name: []const u8,
    namespace: []const u8,
};

test "Token field access" {
    const token = Token{ .name = "deploy", .secret = "sk_a1b2c3", .namespace = "deploy." };
    try std.testing.expectEqualStrings("deploy", token.name);
    try std.testing.expectEqualStrings("sk_a1b2c3", token.secret);
    try std.testing.expectEqualStrings("deploy.", token.namespace);
}

test "ClientIdentity has no secret field" {
    const identity = ClientIdentity{ .name = "deploy", .namespace = "deploy." };
    try std.testing.expectEqualStrings("deploy", identity.name);
    try std.testing.expectEqualStrings("deploy.", identity.namespace);
}
