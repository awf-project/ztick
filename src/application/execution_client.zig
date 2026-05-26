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
            .triggered = .empty,
            .pending = .empty,
            .resolved = .empty,
        };
    }

    pub fn deinit(self: *ExecutionClient) void {
        var it = self.triggered.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.job_identifier);
        }
        self.triggered.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.resolved.deinit(self.allocator);
    }

    pub fn trigger(self: *ExecutionClient, job_identifier: []const u8, runner: Runner, job_execution: i64) !void {
        var bytes: [16]u8 = undefined;
        _ = std.os.linux.getrandom(&bytes, bytes.len, 0);
        const identifier = std.mem.readInt(u128, &bytes, .big);

        const owned_id = try self.allocator.dupe(u8, job_identifier);
        errdefer self.allocator.free(owned_id);

        const request = execution.Request{
            .identifier = identifier,
            .job_identifier = owned_id,
            .runner = runner,
            .execution = job_execution,
        };
        try self.triggered.put(self.allocator, identifier, request);
        errdefer _ = self.triggered.remove(identifier);
        try self.pending.append(self.allocator, request);
    }

    pub fn resolve(self: *ExecutionClient, response: execution.Response) !void {
        try self.resolved.append(self.allocator, response);
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
        var results: std.ArrayListUnmanaged(ExecutionResult) = .empty;
        errdefer results.deinit(allocator);

        for (self.resolved.items) |resp| {
            if (self.triggered.fetchRemove(resp.identifier)) |kv| {
                try results.append(allocator, .{
                    .job_identifier = kv.value.job_identifier,
                    .success = resp.success,
                });
            }
        }

        self.resolved.clearRetainingCapacity();

        return results.toOwnedSlice(allocator);
    }
};

test "trigger stores request in tracking map" {
    const allocator = std.testing.allocator;

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo hello" } }, 0);

    try std.testing.expectEqual(@as(u32, 1), client.triggered.count());
}

test "trigger generates unique identifiers for each invocation" {
    const allocator = std.testing.allocator;

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo a" } }, 0);
    try client.trigger("job.2", .{ .shell = .{ .command = "echo b" } }, 0);

    try std.testing.expectEqual(@as(u32, 2), client.triggered.count());
}

test "pull_results returns execution results for triggered jobs" {
    const allocator = std.testing.allocator;

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo hello" } }, 0);

    const identifier = client.pending.items[0].identifier;
    try client.resolve(.{ .identifier = identifier, .success = true });

    const results = try client.pull_results(allocator);
    defer {
        for (results) |r| allocator.free(r.job_identifier);
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("job.1", results[0].job_identifier);
}

test "pull_results drains tracked executions" {
    const allocator = std.testing.allocator;

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo hello" } }, 0);
    try client.trigger("job.2", .{ .shell = .{ .command = "echo world" } }, 0);

    for (client.pending.items) |req| {
        try client.resolve(.{ .identifier = req.identifier, .success = true });
    }

    const first = try client.pull_results(allocator);
    defer {
        for (first) |r| allocator.free(r.job_identifier);
        allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 2), first.len);

    const second = try client.pull_results(allocator);
    defer allocator.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "resolve stores result successfully" {
    const allocator = std.testing.allocator;

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo hello" } }, 0);
    const identifier = client.pending.items[0].identifier;

    try client.resolve(.{ .identifier = identifier, .success = true });

    try std.testing.expectEqual(@as(usize, 1), client.resolved.items.len);
}

test "resolve returns error on allocation failure" {

    // fail_index = 3: allows 3 allocations (dupe + triggered.put + pending.append in trigger)
    // then fails on resolved.append inside resolve
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    var client = ExecutionClient.init(failing.allocator());
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo hello" } }, 0);
    const identifier = client.pending.items[0].identifier;

    try std.testing.expectError(error.OutOfMemory, client.resolve(.{ .identifier = identifier, .success = true }));

    try std.testing.expectEqual(@as(usize, 0), client.resolved.items.len);
}

test "drain_pending clears only sent prefix on channel closed" {
    const allocator = std.testing.allocator;

    var client = ExecutionClient.init(allocator);
    defer client.deinit();

    try client.trigger("job.1", .{ .shell = .{ .command = "echo a" } }, 0);
    try client.trigger("job.2", .{ .shell = .{ .command = "echo b" } }, 0);
    try client.trigger("job.3", .{ .shell = .{ .command = "echo c" } }, 0);

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
