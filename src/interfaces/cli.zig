const std = @import("std");
const cli = @import("cli");
const version_info = @import("../version.zig");

pub const CliError = error{
    NoCommandSelected,
    UnknownFlag,
    MissingValue,
    UnexpectedPositional,
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

// zig-cli action handlers must be `*const fn () anyerror!void` (zero-arg).
// We capture parsed values into module-level state, then read them from
// `parse()` after the runner returns. State is reset on each parse() call.
var captured: ?Command = null;
var arg_config_path: ?[]const u8 = null;
var arg_dump_logfile: []const u8 = "";
var arg_dump_format: Format = .text;
var arg_dump_compact: bool = false;
var arg_dump_follow: bool = false;

fn server_action() !void {
    captured = Command{ .server = .{ .config_path = arg_config_path } };
}

fn dump_action() !void {
    captured = Command{ .dump = .{ .options = .{
        .logfile_path = arg_dump_logfile,
        .format = arg_dump_format,
        .compact = arg_dump_compact,
        .follow = arg_dump_follow,
    } } };
}

/// Returns true when argv[1] is a known subcommand or a top-level help flag
/// — i.e., when zig-cli can dispatch directly. Otherwise, the user invoked
/// `ztick` (no args) or `ztick -c PATH`, and we transparently default to
/// `server` mode to preserve the daemon-style UX.
fn has_recognized_subcommand(argv: []const []const u8) bool {
    if (argv.len < 2) return false;
    const first = argv[1];
    return std.mem.eql(u8, first, "server") or
        std.mem.eql(u8, first, "dump") or
        std.mem.eql(u8, first, "--help") or
        std.mem.eql(u8, first, "-h");
}

fn is_version_flag(argv: []const []const u8) bool {
    if (argv.len < 2) return false;
    const first = argv[1];
    return std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v");
}

fn print_version(writer: anytype) !void {
    try writer.print("ztick {s}\n", .{version_info.version});
}

/// Inline parser for the implicit-server form (`ztick`, `ztick -c PATH`).
/// Allocates `config_path` on the supplied allocator so the result outlives
/// `argv`. The caller is responsible for freeing it (see main.zig).
fn parse_implicit_server(allocator: std.mem.Allocator, argv: []const []const u8) !Command {
    var config_path_ref: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= argv.len) return CliError.MissingValue;
            config_path_ref = argv[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return CliError.UnknownFlag;
        } else {
            return CliError.UnexpectedPositional;
        }
    }
    const config_dup = if (config_path_ref) |p| try allocator.dupe(u8, p) else null;
    return Command{ .server = .{ .config_path = config_dup } };
}

pub fn parse(allocator: std.mem.Allocator) !Command {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (is_version_flag(argv)) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        print_version(stdout) catch {};
        std.process.exit(0);
    }

    if (!has_recognized_subcommand(argv)) {
        return parse_implicit_server(allocator, argv);
    }

    captured = null;
    arg_config_path = null;
    arg_dump_logfile = "";
    arg_dump_format = .text;
    arg_dump_compact = false;
    arg_dump_follow = false;

    var r = try cli.AppRunner.init(allocator);

    const server_options = try r.allocOptions(&.{
        .{
            .long_name = "config",
            .short_alias = 'c',
            .help = "Path to a TOML configuration file",
            .value_ref = r.mkRef(&arg_config_path),
            .value_name = "PATH",
        },
    });

    const dump_positional = try r.allocPositionalArgs(&.{
        .{
            .name = "LOGFILE",
            .help = "Path to the logfile to dump",
            .value_ref = r.mkRef(&arg_dump_logfile),
        },
    });

    const dump_options = try r.allocOptions(&.{
        .{
            .long_name = "format",
            .help = "Output format: text or json",
            .value_ref = r.mkRef(&arg_dump_format),
            .value_name = "FORMAT",
        },
        .{
            .long_name = "compact",
            .help = "Compact JSON output (no pretty-printing)",
            .value_ref = r.mkRef(&arg_dump_compact),
        },
        .{
            .long_name = "follow",
            .help = "Watch the logfile for new entries",
            .value_ref = r.mkRef(&arg_dump_follow),
        },
    });

    const subcommands = try r.allocCommands(&.{
        .{
            .name = "server",
            .description = .{ .one_line = "Start the ztick scheduler (TCP + optional HTTP)" },
            .options = server_options,
            .target = .{ .action = .{ .exec = server_action } },
        },
        .{
            .name = "dump",
            .description = .{ .one_line = "Dump entries from a ztick logfile" },
            .options = dump_options,
            .target = .{ .action = .{
                .exec = dump_action,
                .positional_args = .{ .required = dump_positional },
            } },
        },
    });

    const app = cli.App{
        .version = version_info.version,
        .command = .{
            .name = "ztick",
            .description = .{
                .one_line = "Time-based job scheduler with rule engine",
            },
            .target = .{ .subcommands = subcommands },
        },
    };

    try r.run(&app);
    return captured orelse CliError.NoCommandSelected;
}

test "implicit-server parser handles bare invocation" {
    const allocator = std.testing.allocator;
    const cmd = try parse_implicit_server(allocator, &.{"ztick"});
    try std.testing.expect(cmd == .server);
    try std.testing.expectEqual(@as(?[]const u8, null), cmd.server.config_path);
}

test "implicit-server parser captures -c PATH" {
    const allocator = std.testing.allocator;
    const cmd = try parse_implicit_server(allocator, &.{ "ztick", "-c", "/etc/ztick.toml" });
    try std.testing.expect(cmd == .server);
    const path = cmd.server.config_path orelse return error.ConfigPathIsNull;
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/etc/ztick.toml", path);
}

test "implicit-server parser captures --config PATH" {
    const allocator = std.testing.allocator;
    const cmd = try parse_implicit_server(allocator, &.{ "ztick", "--config", "/etc/ztick.toml" });
    try std.testing.expect(cmd == .server);
    const path = cmd.server.config_path orelse return error.ConfigPathIsNull;
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/etc/ztick.toml", path);
}

test "implicit-server parser rejects -c with missing value" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(CliError.MissingValue, parse_implicit_server(allocator, &.{ "ztick", "-c" }));
}

test "implicit-server parser rejects unexpected positional" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(CliError.UnexpectedPositional, parse_implicit_server(allocator, &.{ "ztick", "logfile.bin" }));
}

test "implicit-server parser rejects unknown flag" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(CliError.UnknownFlag, parse_implicit_server(allocator, &.{ "ztick", "--unknown" }));
}

test "has_recognized_subcommand detects server, dump, --help" {
    try std.testing.expect(has_recognized_subcommand(&.{ "ztick", "server" }));
    try std.testing.expect(has_recognized_subcommand(&.{ "ztick", "dump" }));
    try std.testing.expect(has_recognized_subcommand(&.{ "ztick", "--help" }));
    try std.testing.expect(has_recognized_subcommand(&.{ "ztick", "-h" }));
    try std.testing.expect(!has_recognized_subcommand(&.{"ztick"}));
    try std.testing.expect(!has_recognized_subcommand(&.{ "ztick", "-c", "/etc/ztick.toml" }));
}

test "is_version_flag detects --version and -v at first position" {
    try std.testing.expect(is_version_flag(&.{ "ztick", "--version" }));
    try std.testing.expect(is_version_flag(&.{ "ztick", "-v" }));
    try std.testing.expect(!is_version_flag(&.{"ztick"}));
    try std.testing.expect(!is_version_flag(&.{ "ztick", "server" }));
    try std.testing.expect(!is_version_flag(&.{ "ztick", "--help" }));
}

test "print_version emits ztick prefix and version with trailing newline" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try print_version(fbs.writer());
    const expected = "ztick " ++ version_info.version ++ "\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}
