const std = @import("std");

pub const LogLevel = enum {
    off,
    @"error",
    warn,
    info,
    debug,
    trace,
};

pub const ConfigError = error{
    InvalidLogLevel,
    FramerateOutOfRange,
    UnknownSection,
    UnknownKey,
    InvalidValue,
};

pub const Config = struct {
    log_level: LogLevel,
    controller_listen: []const u8,
    database_fsync_on_persist: bool,
    database_framerate: u16,
    /// Zig extension: configurable logfile path (Rust reference used hardcoded "logfile").
    database_logfile_path: []const u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.controller_listen);
        allocator.free(self.database_logfile_path);
    }
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) (ConfigError || std.mem.Allocator.Error)!Config {
    var log_level: LogLevel = .info;
    var controller_listen: ?[]u8 = null;
    errdefer if (controller_listen) |cl| allocator.free(cl);
    var database_fsync_on_persist: bool = true;
    var database_framerate: u16 = 512;
    var database_logfile_path: ?[]u8 = null;
    errdefer if (database_logfile_path) |lp| allocator.free(lp);

    var current_section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            current_section = std.mem.trim(u8, line[1..end], " \t");
            if (!std.mem.eql(u8, current_section, "log") and
                !std.mem.eql(u8, current_section, "controller") and
                !std.mem.eql(u8, current_section, "database"))
            {
                return ConfigError.UnknownSection;
            }
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, current_section, "log")) {
            if (std.mem.eql(u8, key, "level")) {
                log_level = std.meta.stringToEnum(LogLevel, unquote(raw_val)) orelse return ConfigError.InvalidLogLevel;
            } else {
                return ConfigError.UnknownKey;
            }
        } else if (std.mem.eql(u8, current_section, "controller")) {
            if (std.mem.eql(u8, key, "listen")) {
                if (controller_listen) |prev| allocator.free(prev);
                controller_listen = try allocator.dupe(u8, unquote(raw_val));
            } else {
                return ConfigError.UnknownKey;
            }
        } else if (std.mem.eql(u8, current_section, "database")) {
            if (std.mem.eql(u8, key, "fsync_on_persist")) {
                if (std.mem.eql(u8, raw_val, "true")) {
                    database_fsync_on_persist = true;
                } else if (std.mem.eql(u8, raw_val, "false")) {
                    database_fsync_on_persist = false;
                } else {
                    return ConfigError.InvalidValue;
                }
            } else if (std.mem.eql(u8, key, "framerate")) {
                const n = std.fmt.parseInt(u16, raw_val, 10) catch return ConfigError.InvalidValue;
                if (n == 0) return ConfigError.FramerateOutOfRange;
                database_framerate = n;
            } else if (std.mem.eql(u8, key, "logfile_path")) {
                if (database_logfile_path) |prev| allocator.free(prev);
                database_logfile_path = try allocator.dupe(u8, unquote(raw_val));
            } else {
                return ConfigError.UnknownKey;
            }
        }
    }

    return Config{
        .log_level = log_level,
        .controller_listen = controller_listen orelse try allocator.dupe(u8, "127.0.0.1:5678"),
        .database_fsync_on_persist = database_fsync_on_persist,
        .database_framerate = database_framerate,
        .database_logfile_path = database_logfile_path orelse try allocator.dupe(u8, "logfile"),
    };
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

pub fn load(allocator: std.mem.Allocator, path: ?[]const u8) !Config {
    const actual_path = path orelse return parse(allocator, "");
    const file = std.fs.cwd().openFile(actual_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return parse(allocator, ""),
        else => return err,
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    return parse(allocator, content);
}

test "parse empty content returns defaults" {
    const cfg = try parse(std.testing.allocator, "");
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(LogLevel.info, cfg.log_level);
    try std.testing.expectEqualStrings("127.0.0.1:5678", cfg.controller_listen);
    try std.testing.expectEqual(true, cfg.database_fsync_on_persist);
    try std.testing.expectEqual(@as(u16, 512), cfg.database_framerate);
}

test "parse overrides log level from toml" {
    const cfg = try parse(std.testing.allocator,
        \\[log]
        \\level = "debug"
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(LogLevel.debug, cfg.log_level);
}

test "parse overrides all fields from toml" {
    const cfg = try parse(std.testing.allocator,
        \\[log]
        \\level = "warn"
        \\[controller]
        \\listen = "0.0.0.0:9000"
        \\[database]
        \\fsync_on_persist = false
        \\framerate = 100
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(LogLevel.warn, cfg.log_level);
    try std.testing.expectEqualStrings("0.0.0.0:9000", cfg.controller_listen);
    try std.testing.expectEqual(false, cfg.database_fsync_on_persist);
    try std.testing.expectEqual(@as(u16, 100), cfg.database_framerate);
}

test "parse rejects invalid log level" {
    const result = parse(std.testing.allocator,
        \\[log]
        \\level = "verbose"
        \\
    );
    try std.testing.expectError(ConfigError.InvalidLogLevel, result);
}

test "parse rejects framerate out of range" {
    const result = parse(std.testing.allocator,
        \\[database]
        \\framerate = 0
        \\
    );
    try std.testing.expectError(ConfigError.FramerateOutOfRange, result);
}

test "parse rejects unknown key in section" {
    const result = parse(std.testing.allocator,
        \\[log]
        \\verbosity = "high"
        \\
    );
    try std.testing.expectError(ConfigError.UnknownKey, result);
}
