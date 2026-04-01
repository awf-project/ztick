const std = @import("std");
const domain = @import("../domain.zig");
const interfaces = @import("../interfaces.zig");

const execution = domain.execution;
const ShellConfig = interfaces.config.ShellConfig;

pub const ShellRunner = struct {
    pub fn execute(allocator: std.mem.Allocator, shell_config: ShellConfig, request: execution.Request) !execution.Response {
        const argv: []const []const u8 = switch (request.runner) {
            .shell => |s| blk: {
                var args = try allocator.alloc([]const u8, shell_config.args.len + 2);
                args[0] = shell_config.path;
                @memcpy(args[1 .. shell_config.args.len + 1], shell_config.args);
                args[shell_config.args.len + 1] = s.command;
                break :blk args;
            },
            .direct => |d| blk: {
                var args = try allocator.alloc([]const u8, d.args.len + 1);
                args[0] = d.executable;
                @memcpy(args[1..], d.args);
                break :blk args;
            },
            .amqp => return error.UnsupportedRunner,
        };
        defer allocator.free(argv);
        var child = std.process.Child.init(argv, allocator);
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

const default_shell_config = ShellConfig{ .path = "/bin/sh", .args = &.{"-c"} };

test "shell runner executes command and reports success on exit code 0" {
    const request = execution.Request{
        .identifier = 1,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 1), response.identifier);
    try std.testing.expect(response.success);
}

test "shell runner reports failure for non-zero exit code" {
    const request = execution.Request{
        .identifier = 2,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/false" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 2), response.identifier);
    try std.testing.expect(!response.success);
}

test "shell runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xdeadbeef_cafebabe,
        .job_identifier = "scheduled.job",
        .runner = .{ .shell = .{ .command = "/bin/echo" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
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
    const response = try ShellRunner.execute(std.testing.allocator, config, request);
    try std.testing.expect(!response.success);
}

test "shell runner executes direct runner without shell wrapper" {
    const request = execution.Request{
        .identifier = 20,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 20), response.identifier);
    try std.testing.expect(response.success);
}

test "direct runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xfeedface_baadf00d,
        .job_identifier = "direct.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 0xfeedface_baadf00d), response.identifier);
}

test "direct runner reports failure for non-zero exit code" {
    const request = execution.Request{
        .identifier = 30,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/false", .args = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
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
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expect(response.success);
}

test "direct runner ignores shell_config and uses direct argv" {
    // Even with an invalid/dummy shell_config, direct runner bypasses it entirely.
    const dummy_config = ShellConfig{ .path = "/nonexistent/shell", .args = &.{"-c"} };
    const request = execution.Request{
        .identifier = 50,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, dummy_config, request);
    try std.testing.expect(response.success);
}
