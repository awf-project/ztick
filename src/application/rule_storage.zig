const std = @import("std");
const domain = @import("../domain.zig");

const Rule = domain.rule.Rule;
const Runner = domain.runner.Runner;

pub const RuleStorage = struct {
    allocator: std.mem.Allocator,
    rules: std.StringHashMapUnmanaged(Rule),

    pub fn init(allocator: std.mem.Allocator) RuleStorage {
        return .{
            .allocator = allocator,
            .rules = .{},
        };
    }

    pub fn deinit(self: *RuleStorage) void {
        self.rules.deinit(self.allocator);
    }

    pub fn get(self: *const RuleStorage, identifier: []const u8) ?Rule {
        return self.rules.get(identifier);
    }

    pub fn set(self: *RuleStorage, rule: Rule) !void {
        try self.rules.put(self.allocator, rule.identifier, rule);
    }

    pub fn delete(self: *RuleStorage, identifier: []const u8) bool {
        return self.rules.remove(identifier);
    }

    pub fn pair(self: *const RuleStorage, job: []const u8) ?Rule {
        var best: ?Rule = null;
        var best_weight: usize = 0;

        var it = self.rules.valueIterator();
        while (it.next()) |rule| {
            if (rule.supports(job)) |weight| {
                if (weight > best_weight) {
                    best_weight = weight;
                    best = rule.*;
                }
            }
        }

        return best;
    }
};

test "set and get" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = RuleStorage.init(allocator);
    defer storage.deinit();

    const rule = Rule{ .identifier = "rule.1", .pattern = "test.", .runner = .{ .shell = .{ .command = "echo" } } };
    try storage.set(rule);

    const result = storage.get("rule.1");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("rule.1", result.?.identifier);
}

test "set overwrites existing rule" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = RuleStorage.init(allocator);
    defer storage.deinit();

    try storage.set(Rule{ .identifier = "rule.1", .pattern = "test.", .runner = .{ .shell = .{ .command = "echo" } } });
    try storage.set(Rule{ .identifier = "rule.1", .pattern = "test.", .runner = .{ .shell = .{ .command = "run" } } });

    const result = storage.get("rule.1");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("run", result.?.runner.shell.command);
}

test "delete removes rule" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = RuleStorage.init(allocator);
    defer storage.deinit();

    try storage.set(Rule{ .identifier = "rule.1", .pattern = "test.", .runner = .{ .shell = .{ .command = "echo" } } });
    const removed = storage.delete("rule.1");
    try std.testing.expect(removed);

    const result = storage.get("rule.1");
    try std.testing.expect(result == null);
}

test "pair returns highest-weight matching rule" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = RuleStorage.init(allocator);
    defer storage.deinit();

    try storage.set(Rule{ .identifier = "rule.1", .pattern = "test.", .runner = .{ .shell = .{ .command = "short" } } });
    try storage.set(Rule{ .identifier = "rule.2", .pattern = "test.job.", .runner = .{ .shell = .{ .command = "long" } } });

    const result = storage.pair("test.job.1");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("long", result.?.runner.shell.command);
}

test "pair returns null when no rule matches" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = RuleStorage.init(allocator);
    defer storage.deinit();

    try storage.set(Rule{ .identifier = "rule.1", .pattern = "test.", .runner = .{ .shell = .{ .command = "echo" } } });

    const result = storage.pair("other.job.1");
    try std.testing.expect(result == null);
}
