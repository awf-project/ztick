const std = @import("std");

pub const CliError = error{
    UnknownFlag,
    MissingValue,
};

pub const Args = struct {
    config_path: ?[]const u8,

    pub fn parse_slice(args: []const []const u8) CliError!Args {
        var config_path: ?[]const u8 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
                i += 1;
                if (i >= args.len) return CliError.MissingValue;
                config_path = args[i];
            } else {
                return CliError.UnknownFlag;
            }
        }
        return Args{ .config_path = config_path };
    }

    pub fn parse(allocator: std.mem.Allocator) anyerror!Args {
        const argv = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, argv);
        const result = try parse_slice(argv[1..]);
        // Dupe config_path so it outlives argsFree
        return Args{
            .config_path = if (result.config_path) |p| try allocator.dupe(u8, p) else null,
        };
    }
};

test "parse no args yields null config path" {
    const args = try Args.parse_slice(&.{});
    try std.testing.expectEqual(@as(?[]const u8, null), args.config_path);
}

test "parse --config sets config path" {
    const args = try Args.parse_slice(&.{ "--config", "/etc/ztick.toml" });
    const path = args.config_path orelse return error.ConfigPathIsNull;
    try std.testing.expectEqualStrings("/etc/ztick.toml", path);
}

test "parse -c sets config path" {
    const args = try Args.parse_slice(&.{ "-c", "/etc/ztick.toml" });
    const path = args.config_path orelse return error.ConfigPathIsNull;
    try std.testing.expectEqualStrings("/etc/ztick.toml", path);
}

test "parse --config without value returns MissingValue" {
    const result = Args.parse_slice(&.{"--config"});
    try std.testing.expectError(CliError.MissingValue, result);
}

test "parse unknown flag returns UnknownFlag" {
    const result = Args.parse_slice(&.{"--verbose"});
    try std.testing.expectError(CliError.UnknownFlag, result);
}
