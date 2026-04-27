const std = @import("std");
const domain = @import("../../domain.zig");

const execution = domain.execution;

pub fn execute(allocator: std.mem.Allocator, payload: anytype, request: execution.Request) execution.Response {
    const argc: usize = 3 + payload.inputs.len * 2;
    const argv = allocator.alloc([]const u8, argc) catch {
        return .{ .identifier = request.identifier, .success = false };
    };
    defer allocator.free(argv);
    argv[0] = "awf";
    argv[1] = "run";
    argv[2] = payload.workflow;
    for (payload.inputs, 0..) |input, i| {
        argv[3 + i * 2] = "--input";
        argv[3 + i * 2 + 1] = input;
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        return .{ .identifier = request.identifier, .success = false };
    };

    const stderr_output = if (child.stderr) |stderr_file|
        stderr_file.readToEndAlloc(allocator, 4096) catch null
    else
        null;
    defer if (stderr_output) |output| allocator.free(output);

    const term = child.wait() catch {
        return .{ .identifier = request.identifier, .success = false };
    };
    const success = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };

    if (stderr_output) |output| {
        if (output.len > 0) {
            std.log.debug("awf stderr: {s}", .{output});
        }
    }

    return .{
        .identifier = request.identifier,
        .success = success,
    };
}

test "awf runner reports failure for non-zero exit from awf process" {
    const request = execution.Request{
        .identifier = 100,
        .job_identifier = "test.job",
        .runner = .{ .awf = .{ .workflow = "nonexistent-workflow", .inputs = &.{} } },
    };
    const response = execute(std.testing.allocator, request.runner.awf, request);
    try std.testing.expectEqual(@as(u128, 100), response.identifier);
    try std.testing.expect(!response.success);
}

test "awf runner with inputs passes --input arguments to awf process" {
    const inputs = [_][]const u8{"format=pdf"};
    const request = execution.Request{
        .identifier = 110,
        .job_identifier = "test.job",
        .runner = .{ .awf = .{ .workflow = "nonexistent-workflow", .inputs = &inputs } },
    };
    const response = execute(std.testing.allocator, request.runner.awf, request);
    try std.testing.expectEqual(@as(u128, 110), response.identifier);
    try std.testing.expect(!response.success);
}

test "awf runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xbeefcafe_12345678,
        .job_identifier = "awf.job",
        .runner = .{ .awf = .{ .workflow = "nonexistent-workflow", .inputs = &.{} } },
    };
    const response = execute(std.testing.allocator, request.runner.awf, request);
    try std.testing.expectEqual(@as(u128, 0xbeefcafe_12345678), response.identifier);
}
