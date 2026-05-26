const std = @import("std");
const domain = @import("../../domain.zig");
const subprocess = @import("subprocess.zig");

const execution = domain.execution;
const ShellConfig = domain.shell_config.ShellConfig;

pub fn execute(io: std.Io, allocator: std.mem.Allocator, shell_config: ShellConfig, payload: anytype, request: execution.Request) execution.Response {
    const args = allocator.alloc([]const u8, shell_config.args.len + 2) catch {
        return .{ .identifier = request.identifier, .success = false };
    };
    defer allocator.free(args);
    args[0] = shell_config.path;
    @memcpy(args[1 .. shell_config.args.len + 1], shell_config.args);
    args[shell_config.args.len + 1] = payload.command;
    return subprocess.run(io, allocator, args, request.identifier);
}

const default_shell_config = ShellConfig{ .path = "/bin/sh", .args = &.{"-c"} };

test "shell runner executes command and reports success on exit code 0" {
    const request = execution.Request{
        .identifier = 1,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };
    const response = execute(std.testing.io, std.testing.allocator, default_shell_config, request.runner.shell, request);
    try std.testing.expectEqual(@as(u128, 1), response.identifier);
    try std.testing.expect(response.success);
}

test "shell runner reports failure for non-zero exit code" {
    const request = execution.Request{
        .identifier = 2,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/false" } },
    };
    const response = execute(std.testing.io, std.testing.allocator, default_shell_config, request.runner.shell, request);
    try std.testing.expectEqual(@as(u128, 2), response.identifier);
    try std.testing.expect(!response.success);
}

test "shell runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xdeadbeef_cafebabe,
        .job_identifier = "scheduled.job",
        .runner = .{ .shell = .{ .command = "/bin/echo" } },
    };
    const response = execute(std.testing.io, std.testing.allocator, default_shell_config, request.runner.shell, request);
    try std.testing.expectEqual(@as(u128, 0xdeadbeef_cafebabe), response.identifier);
}

test "shell runner uses configured shell path instead of hardcoded /bin/sh" {
    // /bin/false as the shell binary means any command invocation exits non-zero,
    // proving the config path is used rather than the hardcoded default.
    const config = ShellConfig{ .path = "/bin/false", .args = &.{"-c"} };
    const request = execution.Request{
        .identifier = 10,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };
    const response = execute(std.testing.io, std.testing.allocator, config, request.runner.shell, request);
    try std.testing.expect(!response.success);
}
