const std = @import("std");
const domain = @import("../domain.zig");

const execution = domain.execution;
const Runner = domain.runner.Runner;

pub const ExecutionResult = struct {
    job_identifier: []const u8,
    success: bool,
};

pub const ExecutionClient = struct {
    allocator: std.mem.Allocator,
    triggered: std.AutoHashMapUnmanaged(u128, execution.Request),
    pending: std.ArrayListUnmanaged(execution.Request),
    resolved: std.ArrayListUnmanaged(execution.Response),

    pub fn init(allocator: std.mem.Allocator) ExecutionClient {
        return .{
            .allocator = allocator,
            .triggered = .{},
            .pending = .{},
            .resolved = .{},
        };
    }

    pub fn deinit(self: *ExecutionClient) void {
        self.triggered.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.resolved.deinit(self.allocator);
    }

    pub fn trigger(self: *ExecutionClient, job_identifier: []const u8, runner: Runner) !void {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        const identifier = std.mem.readInt(u128, &bytes, .big);

        const request = execution.Request{
            .identifier = identifier,
            .job_identifier = job_identifier,
            .runner = runner,
        };
        try self.triggered.put(self.allocator, identifier, request);
        try self.pending.append(self.allocator, request);
    }

    pub fn resolve(self: *ExecutionClient, response: execution.Response) void {
        self.resolved.append(self.allocator, response) catch {};
    }

    pub fn drain_pending(self: *ExecutionClient, sender: anytype) void {
        var sent: usize = 0;
        for (self.pending.items) |req| {
            sender.send(req) catch break;
            sent += 1;
        }
        if (sent > 0) {
            const remaining = self.pending.items.len - sent;
            if (remaining > 0) {
                std.mem.copyForwards(execution.Request, self.pending.items[0..remaining], self.pending.items[sent..]);
            }
            self.pending.shrinkRetainingCapacity(remaining);
        }
    }

    pub fn pull_results(self: *ExecutionClient, allocator: std.mem.Allocator) ![]ExecutionResult {
        var results = std.ArrayListUnmanaged(ExecutionResult){};
        errdefer results.deinit(allocator);

        for (self.resolved.items) |resp| {
            if (self.triggered.get(resp.identifier)) |req| {
                try results.append(allocator, .{
                    .job_identifier = req.job_identifier,
                    .success = resp.success,
                });
                _ = self.triggered.remove(resp.identifier);
            }
        }

        self.resolved.clearRetainingCapacity();

        return results.toOwnedSlice(allocator);
    }
};

test "trigger stores request in tracking map" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo hello" } });

    try std.testing.expectEqual(@as(u32, 1), client.triggered.count());
}

test "trigger generates unique identifiers for each invocation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo a" } });
    try client.trigger("job.2", .{ .shell = .{ .command = "echo b" } });

    try std.testing.expectEqual(@as(u32, 2), client.triggered.count());
}

test "pull_results returns execution results for triggered jobs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo hello" } });

    const identifier = client.pending.items[0].identifier;
    client.resolve(.{ .identifier = identifier, .success = true });

    const results = try client.pull_results(allocator);
    defer allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("job.1", results[0].job_identifier);
}

test "pull_results drains tracked executions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo hello" } });
    try client.trigger("job.2", .{ .shell = .{ .command = "echo world" } });

    for (client.pending.items) |req| {
        client.resolve(.{ .identifier = req.identifier, .success = true });
    }

    const first = try client.pull_results(allocator);
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 2), first.len);

    const second = try client.pull_results(allocator);
    defer allocator.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "drain_pending clears only sent prefix on channel closed" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo a" } });
    try client.trigger("job.2", .{ .shell = .{ .command = "echo b" } });
    try client.trigger("job.3", .{ .shell = .{ .command = "echo c" } });

    // Mock sender that fails after accepting 2 items.
    const FailAfter2 = struct {
        count: usize = 0,
        const ChannelError = error{ChannelClosed};
        fn send(self: *@This(), _: execution.Request) ChannelError!void {
            if (self.count >= 2) return error.ChannelClosed;
            self.count += 1;
        }
    };

    var mock = FailAfter2{};
    client.drain_pending(&mock);

    try std.testing.expectEqual(@as(usize, 2), mock.count);
    try std.testing.expectEqual(@as(usize, 1), client.pending.items.len);
    try std.testing.expectEqualStrings("job.3", client.pending.items[0].job_identifier);
}
