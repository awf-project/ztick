const std = @import("std");
const domain = @import("../../domain.zig");

const execution = domain.execution;

pub fn execute(io: std.Io, allocator: std.mem.Allocator, payload: anytype, request: execution.Request) execution.Response {
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

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch {
        return .{ .identifier = request.identifier, .success = false };
    };

    var stderr_buf: [65536]u8 = undefined;
    const stderr_output: ?[]u8 = if (child.stderr) |stderr_file| blk: {
        var r = stderr_file.reader(io, &stderr_buf);
        var list: std.ArrayList(u8) = .empty;
        r.interface.appendRemaining(allocator, &list, .limited(stderr_buf.len)) catch {
            list.deinit(allocator);
            break :blk null;
        };
        break :blk list.toOwnedSlice(allocator) catch null;
    } else null;
    defer if (stderr_output) |output| allocator.free(output);

    const term = child.wait(io) catch {
        return .{ .identifier = request.identifier, .success = false };
    };
    const success = switch (term) {
        .exited => |code| code == 0,
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
    const response = execute(std.testing.io, std.testing.allocator, request.runner.awf, request);
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
    const response = execute(std.testing.io, std.testing.allocator, request.runner.awf, request);
    try std.testing.expectEqual(@as(u128, 110), response.identifier);
    try std.testing.expect(!response.success);
}

test "awf runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xbeefcafe_12345678,
        .job_identifier = "awf.job",
        .runner = .{ .awf = .{ .workflow = "nonexistent-workflow", .inputs = &.{} } },
    };
    const response = execute(std.testing.io, std.testing.allocator, request.runner.awf, request);
    try std.testing.expectEqual(@as(u128, 0xbeefcafe_12345678), response.identifier);
}
