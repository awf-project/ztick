const std = @import("std");
const domain = @import("../../domain.zig");

const execution = domain.execution;

pub fn execute(allocator: std.mem.Allocator, payload: anytype, request: execution.Request) execution.Response {
    const args = allocator.alloc([]const u8, payload.args.len + 1) catch {
        return .{ .identifier = request.identifier, .success = false };
    };
    defer allocator.free(args);
    args[0] = payload.executable;
    @memcpy(args[1..], payload.args);

    var child = std.process.Child.init(args, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        return .{ .identifier = request.identifier, .success = false };
    };

    const term = child.wait() catch {
        return .{ .identifier = request.identifier, .success = false };
    };
    const success = switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };

    return .{ .identifier = request.identifier, .success = success };
}

test "direct runner executes binary without shell wrapper" {
    const request = execution.Request{
        .identifier = 20,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    const response = execute(std.testing.allocator, request.runner.direct, request);
    try std.testing.expectEqual(@as(u128, 20), response.identifier);
    try std.testing.expect(response.success);
}

test "direct runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xfeedface_baadf00d,
        .job_identifier = "direct.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    const response = execute(std.testing.allocator, request.runner.direct, request);
    try std.testing.expectEqual(@as(u128, 0xfeedface_baadf00d), response.identifier);
}

test "direct runner reports failure for non-zero exit code" {
    const request = execution.Request{
        .identifier = 30,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/false", .args = &.{} } },
    };
    const response = execute(std.testing.allocator, request.runner.direct, request);
    try std.testing.expectEqual(@as(u128, 30), response.identifier);
    try std.testing.expect(!response.success);
}

test "direct runner passes arguments as literal argv elements without shell interpretation" {
    // If shell-interpreted: "/bin/echo hello; /bin/false" would run /bin/false and exit non-zero.
    // With direct execution: the semicolon is a literal arg to /bin/echo, which exits 0.
    const args = [_][]const u8{"hello; /bin/false"};
    const request = execution.Request{
        .identifier = 40,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/echo", .args = &args } },
    };
    const response = execute(std.testing.allocator, request.runner.direct, request);
    try std.testing.expect(response.success);
}
