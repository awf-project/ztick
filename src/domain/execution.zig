const std = @import("std");
const runner = @import("runner.zig");

pub const Request = struct {
    identifier: u128,
    job_identifier: []const u8,
    runner: runner.Runner,
    execution: i64 = 0,
};

pub const Response = struct {
    identifier: u128,
    success: bool,
};

test "execution request stores identifier job_identifier and runner" {
    const req = Request{
        .identifier = 0xdeadbeef,
        .job_identifier = "job.1",
        .runner = .{ .shell = .{ .command = "echo" } },
    };
    try std.testing.expectEqual(@as(u128, 0xdeadbeef), req.identifier);
    try std.testing.expectEqualStrings("job.1", req.job_identifier);
    try std.testing.expectEqualStrings("echo", req.runner.shell.command);
}

test "execution response links identifier and reports success" {
    const resp = Response{ .identifier = 0xdeadbeef, .success = true };
    try std.testing.expectEqual(@as(u128, 0xdeadbeef), resp.identifier);
    try std.testing.expect(resp.success);
}
