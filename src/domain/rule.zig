const std = @import("std");
const runner_mod = @import("runner.zig");

pub const Runner = runner_mod.Runner;

pub const Rule = struct {
    identifier: []const u8,
    pattern: []const u8,
    runner: Runner,

    pub fn supports(self: *const Rule, job: []const u8) ?usize {
        if (std.mem.startsWith(u8, job, self.pattern)) {
            return self.pattern.len;
        }
        return null;
    }
};

test "supports returns pattern length when job starts with pattern" {
    const rule = Rule{
        .identifier = "rule.1",
        .pattern = "test.",
        .runner = .{ .shell = .{ .command = "echo" } },
    };

    const weight = rule.supports("test.0");
    try std.testing.expect(weight != null);
    try std.testing.expectEqual(@as(usize, 5), weight.?);
}

test "supports returns null when job does not start with pattern" {
    const rule = Rule{
        .identifier = "rule.1",
        .pattern = "test.",
        .runner = .{ .shell = .{ .command = "echo" } },
    };

    const weight = rule.supports("test0");
    try std.testing.expect(weight == null);
}
