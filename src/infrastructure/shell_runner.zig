const std = @import("std");
const domain = @import("../domain.zig");

const execution = domain.execution;

pub const ShellRunner = struct {
    pub fn execute(allocator: std.mem.Allocator, request: execution.Request) !execution.Response {
        const command = switch (request.runner) {
            .shell => |s| s.command,
            .amqp => return error.UnsupportedRunner,
        };
        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", command }, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        const term = try child.wait();
        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
        return execution.Response{
            .identifier = request.identifier,
            .success = success,
        };
    }
};

test "shell runner executes command and reports success on exit code 0" {
    const request = execution.Request{
        .identifier = 1,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, request);
    try std.testing.expectEqual(@as(u128, 1), response.identifier);
    try std.testing.expect(response.success);
}

test "shell runner reports failure for non-zero exit code" {
    const request = execution.Request{
        .identifier = 2,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/false" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, request);
    try std.testing.expectEqual(@as(u128, 2), response.identifier);
    try std.testing.expect(!response.success);
}

test "shell runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xdeadbeef_cafebabe,
        .job_identifier = "scheduled.job",
        .runner = .{ .shell = .{ .command = "/bin/echo" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, request);
    try std.testing.expectEqual(@as(u128, 0xdeadbeef_cafebabe), response.identifier);
}
