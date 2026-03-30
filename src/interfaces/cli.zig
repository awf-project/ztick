const std = @import("std");

pub const CliError = error{
    UnknownFlag,
    MissingValue,
    InvalidValue,
};

pub const Format = enum {
    text,
    json,
};

pub const DumpOptions = struct {
    logfile_path: []const u8,
    format: Format,
    compact: bool,
    follow: bool,
};

pub const Command = union(enum) {
    server: struct { config_path: ?[]const u8 },
    dump: struct { options: DumpOptions },
};

pub fn parse_slice(args: []const []const u8) CliError!Command {
    if (args.len > 0 and std.mem.eql(u8, args[0], "dump")) {
        return parse_dump(args[1..]);
    }
    return parse_server(args);
}

fn parse_server(args: []const []const u8) CliError!Command {
    var config_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            config_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return CliError.UnknownFlag;
        }
    }
    return Command{ .server = .{ .config_path = config_path } };
}

fn parse_dump(args: []const []const u8) CliError!Command {
    if (args.len == 0) return CliError.MissingValue;

    const logfile_path = args[0];
    var format = Format.text;
    var compact = false;
    var follow = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) return CliError.MissingValue;
            const fmt = args[i];
            if (std.mem.eql(u8, fmt, "text")) {
                format = .text;
            } else if (std.mem.eql(u8, fmt, "json")) {
                format = .json;
            } else {
                return CliError.InvalidValue;
            }
        } else if (std.mem.eql(u8, arg, "--compact")) {
            compact = true;
        } else if (std.mem.eql(u8, arg, "--follow")) {
            follow = true;
        } else {
            return CliError.UnknownFlag;
        }
    }

    return Command{ .dump = .{ .options = .{
        .logfile_path = logfile_path,
        .format = format,
        .compact = compact,
        .follow = follow,
    } } };
}

pub fn parse(allocator: std.mem.Allocator) anyerror!Command {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    var cmd = try parse_slice(argv[1..]);
    switch (cmd) {
        .server => |*s| {
            if (s.config_path) |p| s.config_path = try allocator.dupe(u8, p);
        },
        .dump => |*d| {
            d.options.logfile_path = try allocator.dupe(u8, d.options.logfile_path);
        },
    }
    return cmd;
}

test "parse no args returns server command" {
    const cmd = try parse_slice(&.{});
    try std.testing.expect(cmd == .server);
    try std.testing.expectEqual(@as(?[]const u8, null), cmd.server.config_path);
}

test "parse --config returns server command with config path" {
    const cmd = try parse_slice(&.{ "--config", "/etc/ztick.toml" });
    try std.testing.expect(cmd == .server);
    const path = cmd.server.config_path orelse return error.ConfigPathIsNull;
    try std.testing.expectEqualStrings("/etc/ztick.toml", path);
}

test "parse -c returns server command with config path" {
    const cmd = try parse_slice(&.{ "-c", "/etc/ztick.toml" });
    try std.testing.expect(cmd == .server);
    const path = cmd.server.config_path orelse return error.ConfigPathIsNull;
    try std.testing.expectEqualStrings("/etc/ztick.toml", path);
}

test "parse dump with logfile path returns dump command" {
    const cmd = try parse_slice(&.{ "dump", "logfile.bin" });
    try std.testing.expect(cmd == .dump);
    try std.testing.expectEqualStrings("logfile.bin", cmd.dump.options.logfile_path);
}

test "parse dump with --format json returns json format" {
    const cmd = try parse_slice(&.{ "dump", "logfile.bin", "--format", "json" });
    try std.testing.expect(cmd == .dump);
    try std.testing.expectEqual(Format.json, cmd.dump.options.format);
}

test "parse dump with --compact returns compact true" {
    const cmd = try parse_slice(&.{ "dump", "logfile.bin", "--compact" });
    try std.testing.expect(cmd == .dump);
    try std.testing.expect(cmd.dump.options.compact);
}

test "parse dump with --follow returns follow true" {
    const cmd = try parse_slice(&.{ "dump", "logfile.bin", "--follow" });
    try std.testing.expect(cmd == .dump);
    try std.testing.expect(cmd.dump.options.follow);
}

test "parse dump without logfile path returns MissingValue" {
    const result = parse_slice(&.{"dump"});
    try std.testing.expectError(CliError.MissingValue, result);
}

test "parse dump with unknown format returns InvalidValue" {
    const result = parse_slice(&.{ "dump", "logfile.bin", "--format", "xml" });
    try std.testing.expectError(CliError.InvalidValue, result);
}

test "parse unknown flag returns UnknownFlag" {
    const result = parse_slice(&.{"--verbose"});
    try std.testing.expectError(CliError.UnknownFlag, result);
}
