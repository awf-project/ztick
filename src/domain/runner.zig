pub const Runner = union(enum) {
    shell: struct {
        command: []const u8,
    },
    amqp: struct {
        dsn: []const u8,
        exchange: []const u8,
        routing_key: []const u8,
    },
    direct: struct {
        executable: []const u8,
        args: []const []const u8,
    },
};

const std = @import("std");

test "direct runner stores executable path" {
    const runner = Runner{ .direct = .{ .executable = "/bin/echo", .args = &.{} } };
    try std.testing.expectEqualStrings("/bin/echo", runner.direct.executable);
    try std.testing.expectEqual(@as(usize, 0), runner.direct.args.len);
}

test "direct runner stores args as separate elements" {
    const args = [_][]const u8{ "-s", "http://example.com" };
    const runner = Runner{ .direct = .{ .executable = "/usr/bin/curl", .args = &args } };
    try std.testing.expectEqualStrings("/usr/bin/curl", runner.direct.executable);
    try std.testing.expectEqual(@as(usize, 2), runner.direct.args.len);
    try std.testing.expectEqualStrings("-s", runner.direct.args[0]);
    try std.testing.expectEqualStrings("http://example.com", runner.direct.args[1]);
}

test "direct runner is matched by exhaustive switch" {
    const args = [_][]const u8{"hello world"};
    const runner = Runner{ .direct = .{ .executable = "/bin/echo", .args = &args } };
    const tag: []const u8 = switch (runner) {
        .shell => "shell",
        .amqp => "amqp",
        .direct => "direct",
    };
    try std.testing.expectEqualStrings("direct", tag);
}
