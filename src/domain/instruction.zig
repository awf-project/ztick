const std = @import("std");
const runner = @import("runner.zig");

pub const Instruction = union(enum) {
    set: struct {
        identifier: []const u8,
        execution: i64,
    },
    rule_set: struct {
        identifier: []const u8,
        pattern: []const u8,
        runner: runner.Runner,
    },
};

test "set instruction stores identifier and execution timestamp" {
    const instr = Instruction{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } };
    try std.testing.expectEqualStrings("job.1", instr.set.identifier);
    try std.testing.expectEqual(@as(i64, 1595586600_000000000), instr.set.execution);
    try std.testing.expectEqual(std.meta.Tag(Instruction).set, std.meta.activeTag(instr));
}

test "rule_set instruction stores identifier pattern and runner" {
    const instr = Instruction{ .rule_set = .{
        .identifier = "rule.1",
        .pattern = "job.",
        .runner = .{ .shell = .{ .command = "echo" } },
    } };
    try std.testing.expectEqualStrings("rule.1", instr.rule_set.identifier);
    try std.testing.expectEqualStrings("job.", instr.rule_set.pattern);
    try std.testing.expectEqualStrings("echo", instr.rule_set.runner.shell.command);
    try std.testing.expectEqual(std.meta.Tag(Instruction).rule_set, std.meta.activeTag(instr));
}
