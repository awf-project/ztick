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

/// Compares two byte slices in constant time to prevent timing attacks.
/// Returns false immediately when lengths differ (length is not secret);
/// otherwise accumulates XOR differences without early exit.
pub fn constant_time_eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

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

test "constant_time_eql returns true for identical slices" {
    try std.testing.expect(constant_time_eql("sk_abc123", "sk_abc123"));
}

test "constant_time_eql returns false for differing slices of same length" {
    try std.testing.expect(!constant_time_eql("sk_abc123", "sk_abc124"));
}

test "constant_time_eql returns false for slices of different lengths" {
    try std.testing.expect(!constant_time_eql("sk_abc", "sk_abc123"));
}

test "constant_time_eql returns true for empty slices" {
    try std.testing.expect(constant_time_eql("", ""));
}

test "constant_time_eql returns false when only first byte differs" {
    try std.testing.expect(!constant_time_eql("Xk_abc123", "sk_abc123"));
}

test "constant_time_eql returns false when only last byte differs" {
    try std.testing.expect(!constant_time_eql("sk_abc12X", "sk_abc123"));
}
