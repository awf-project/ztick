const std = @import("std");

/// Configuration for the shell interpreter used by the shell runner.
/// This is pure data with no infrastructure dependencies.
pub const ShellConfig = struct {
    path: []const u8,
    args: []const []const u8,

    pub fn deinit(self: ShellConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
    }
};

test "ShellConfig stores path and args" {
    const config = ShellConfig{ .path = "/bin/sh", .args = &.{"-c"} };
    try std.testing.expectEqualStrings("/bin/sh", config.path);
    try std.testing.expectEqual(@as(usize, 1), config.args.len);
    try std.testing.expectEqualStrings("-c", config.args[0]);
}

test "ShellConfig deinit frees allocated memory without leaking" {
    const allocator = std.testing.allocator;
    const path = try allocator.dupe(u8, "/bin/bash");
    const arg = try allocator.dupe(u8, "-c");
    const args = try allocator.alloc([]const u8, 1);
    args[0] = arg;
    const config = ShellConfig{ .path = path, .args = args };
    config.deinit(allocator);
    // std.testing.allocator will detect leaks if deinit is incomplete
}
