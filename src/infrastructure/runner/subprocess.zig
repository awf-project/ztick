const std = @import("std");
const domain = @import("../../domain.zig");

const execution = domain.execution;

/// Spawn a subprocess with the given argv, wait for exit, and return a Response.
/// The caller is responsible for constructing and freeing the argv slice.
pub fn run(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, identifier: u128) execution.Response {
    _ = allocator;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {
        return .{ .identifier = identifier, .success = false };
    };
    const term = child.wait(io) catch {
        return .{ .identifier = identifier, .success = false };
    };
    const success = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .identifier = identifier, .success = success };
}

test "subprocess run returns success for zero exit code" {
    const argv = [_][]const u8{"/bin/true"};
    const response = run(std.testing.io, std.testing.allocator, &argv, 100);
    try std.testing.expectEqual(@as(u128, 100), response.identifier);
    try std.testing.expect(response.success);
}

test "subprocess run returns failure for non-zero exit code" {
    const argv = [_][]const u8{"/bin/false"};
    const response = run(std.testing.io, std.testing.allocator, &argv, 200);
    try std.testing.expectEqual(@as(u128, 200), response.identifier);
    try std.testing.expect(!response.success);
}

test "subprocess run returns failure for nonexistent binary" {
    const argv = [_][]const u8{"/nonexistent/binary"};
    const response = run(std.testing.io, std.testing.allocator, &argv, 300);
    try std.testing.expectEqual(@as(u128, 300), response.identifier);
    try std.testing.expect(!response.success);
}

test "subprocess run preserves identifier in response" {
    const argv = [_][]const u8{"/bin/true"};
    const response = run(std.testing.io, std.testing.allocator, &argv, 0xdeadbeef_deadbeef);
    try std.testing.expectEqual(@as(u128, 0xdeadbeef_deadbeef), response.identifier);
}
