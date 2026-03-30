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
    get: struct {
        identifier: []const u8,
    },
    query: struct {
        pattern: []const u8,
    },
    remove: struct {
        identifier: []const u8,
    },
    remove_rule: struct {
        identifier: []const u8,
    },
    list_rules: struct {},
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

test "get instruction stores identifier" {
    const instr = Instruction{ .get = .{ .identifier = "job.1" } };
    try std.testing.expectEqualStrings("job.1", instr.get.identifier);
    try std.testing.expectEqual(std.meta.Tag(Instruction).get, std.meta.activeTag(instr));
}

test "query instruction stores pattern" {
    const instr = Instruction{ .query = .{ .pattern = "backup." } };
    try std.testing.expectEqualStrings("backup.", instr.query.pattern);
    try std.testing.expectEqual(std.meta.Tag(Instruction).query, std.meta.activeTag(instr));
}

test "query instruction accepts empty pattern" {
    const instr = Instruction{ .query = .{ .pattern = "" } };
    try std.testing.expectEqualStrings("", instr.query.pattern);
    try std.testing.expectEqual(std.meta.Tag(Instruction).query, std.meta.activeTag(instr));
}

test "remove instruction stores identifier" {
    const instr = Instruction{ .remove = .{ .identifier = "backup-daily" } };
    try std.testing.expectEqualStrings("backup-daily", instr.remove.identifier);
    try std.testing.expectEqual(std.meta.Tag(Instruction).remove, std.meta.activeTag(instr));
}

test "remove_rule instruction stores identifier" {
    const instr = Instruction{ .remove_rule = .{ .identifier = "notify-slack" } };
    try std.testing.expectEqualStrings("notify-slack", instr.remove_rule.identifier);
    try std.testing.expectEqual(std.meta.Tag(Instruction).remove_rule, std.meta.activeTag(instr));
}

test "list_rules instruction is active tag" {
    const instr = Instruction{ .list_rules = .{} };
    try std.testing.expectEqual(std.meta.Tag(Instruction).list_rules, std.meta.activeTag(instr));
}
