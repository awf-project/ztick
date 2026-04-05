const std = @import("std");

pub const LogLevel = enum {
    off,
    @"error",
    warn,
    info,
    debug,
    trace,
};

pub const PersistenceMode = enum {
    logfile,
    memory,
};

pub const TelemetryConfig = struct {
    enabled: bool,
    endpoint: ?[]const u8,
    service_name: []const u8,
    flush_interval_ms: u32,
};

pub const ConfigError = error{
    InvalidLogLevel,
    FramerateOutOfRange,
    UnknownSection,
    UnknownKey,
    InvalidValue,
    InvalidShellPath,
};

pub const ShellConfig = struct {
    path: []const u8,
    args: []const []const u8,

    pub fn deinit(self: ShellConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
    }

    pub fn validate(self: ShellConfig) ConfigError!void {
        std.posix.access(self.path, std.posix.X_OK) catch return ConfigError.InvalidShellPath;
    }
};

pub const Config = struct {
    log_level: LogLevel,
    controller_listen: []const u8,
    controller_tls_cert: ?[]const u8,
    controller_tls_key: ?[]const u8,
    database_fsync_on_persist: bool,
    database_framerate: u16,
    /// Zig extension: configurable logfile path (Rust reference used hardcoded "logfile").
    database_logfile_path: []const u8,
    database_persistence: PersistenceMode,
    database_compression_interval: u32,
    telemetry: TelemetryConfig,
    shell: ShellConfig,
    http_listen: ?[]const u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.controller_listen);
        if (self.controller_tls_cert) |cert| allocator.free(cert);
        if (self.controller_tls_key) |key| allocator.free(key);
        allocator.free(self.database_logfile_path);
        if (self.telemetry.endpoint) |ep| allocator.free(ep);
        allocator.free(self.telemetry.service_name);
        self.shell.deinit(allocator);
        if (self.http_listen) |hl| allocator.free(hl);
    }
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) (ConfigError || std.mem.Allocator.Error)!Config {
    var log_level: LogLevel = .info;
    var controller_listen: ?[]u8 = null;
    errdefer if (controller_listen) |cl| allocator.free(cl);
    var controller_tls_cert: ?[]u8 = null;
    errdefer if (controller_tls_cert) |cert| allocator.free(cert);
    var controller_tls_key: ?[]u8 = null;
    errdefer if (controller_tls_key) |key| allocator.free(key);
    var database_fsync_on_persist: bool = true;
    var database_framerate: u16 = 512;
    var database_logfile_path: ?[]u8 = null;
    errdefer if (database_logfile_path) |lp| allocator.free(lp);
    var database_persistence: PersistenceMode = .logfile;
    var database_compression_interval: u32 = 3600;
    var telemetry_enabled: bool = false;
    var telemetry_endpoint: ?[]u8 = null;
    errdefer if (telemetry_endpoint) |ep| allocator.free(ep);
    var telemetry_service_name: ?[]u8 = null;
    errdefer if (telemetry_service_name) |sn| allocator.free(sn);
    var telemetry_flush_interval_ms: u32 = 5000;
    var shell_path: ?[]u8 = null;
    errdefer if (shell_path) |sp| allocator.free(sp);
    var shell_args: ?[]const []const u8 = null;
    errdefer if (shell_args) |args| {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    };
    var http_listen: ?[]u8 = null;
    errdefer if (http_listen) |hl| allocator.free(hl);

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
                !std.mem.eql(u8, current_section, "database") and
                !std.mem.eql(u8, current_section, "telemetry") and
                !std.mem.eql(u8, current_section, "shell") and
                !std.mem.eql(u8, current_section, "http"))
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
            } else if (std.mem.eql(u8, key, "tls_cert")) {
                if (controller_tls_cert) |prev| allocator.free(prev);
                controller_tls_cert = try allocator.dupe(u8, unquote(raw_val));
            } else if (std.mem.eql(u8, key, "tls_key")) {
                if (controller_tls_key) |prev| allocator.free(prev);
                controller_tls_key = try allocator.dupe(u8, unquote(raw_val));
            } else {
                return ConfigError.UnknownKey;
            }
        } else if (std.mem.eql(u8, current_section, "telemetry")) {
            if (std.mem.eql(u8, key, "enabled")) {
                if (std.mem.eql(u8, raw_val, "true")) {
                    telemetry_enabled = true;
                } else if (std.mem.eql(u8, raw_val, "false")) {
                    telemetry_enabled = false;
                } else {
                    return ConfigError.InvalidValue;
                }
            } else if (std.mem.eql(u8, key, "endpoint")) {
                if (telemetry_endpoint) |prev| allocator.free(prev);
                telemetry_endpoint = try allocator.dupe(u8, unquote(raw_val));
            } else if (std.mem.eql(u8, key, "service_name")) {
                if (telemetry_service_name) |prev| allocator.free(prev);
                telemetry_service_name = try allocator.dupe(u8, unquote(raw_val));
            } else if (std.mem.eql(u8, key, "flush_interval_ms")) {
                telemetry_flush_interval_ms = std.fmt.parseInt(u32, raw_val, 10) catch return ConfigError.InvalidValue;
            } else {
                return ConfigError.UnknownKey;
            }
        } else if (std.mem.eql(u8, current_section, "shell")) {
            if (std.mem.eql(u8, key, "path")) {
                if (shell_path) |prev| allocator.free(prev);
                shell_path = try allocator.dupe(u8, unquote(raw_val));
            } else if (std.mem.eql(u8, key, "args")) {
                if (shell_args) |prev| {
                    for (prev) |arg| allocator.free(arg);
                    allocator.free(prev);
                }
                shell_args = try parse_toml_string_array(allocator, raw_val);
            } else {
                return ConfigError.UnknownKey;
            }
        } else if (std.mem.eql(u8, current_section, "http")) {
            if (std.mem.eql(u8, key, "listen")) {
                if (http_listen) |prev| allocator.free(prev);
                http_listen = try allocator.dupe(u8, unquote(raw_val));
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
            } else if (std.mem.eql(u8, key, "persistence")) {
                database_persistence = std.meta.stringToEnum(PersistenceMode, unquote(raw_val)) orelse return ConfigError.InvalidValue;
            } else if (std.mem.eql(u8, key, "compression_interval")) {
                database_compression_interval = std.fmt.parseInt(u32, raw_val, 10) catch return ConfigError.InvalidValue;
            } else {
                return ConfigError.UnknownKey;
            }
        }
    }

    if ((controller_tls_cert != null) != (controller_tls_key != null)) {
        return ConfigError.InvalidValue;
    }

    return Config{
        .log_level = log_level,
        .controller_listen = controller_listen orelse try allocator.dupe(u8, "127.0.0.1:5678"),
        .controller_tls_cert = controller_tls_cert,
        .controller_tls_key = controller_tls_key,
        .database_fsync_on_persist = database_fsync_on_persist,
        .database_framerate = database_framerate,
        .database_logfile_path = database_logfile_path orelse try allocator.dupe(u8, "logfile"),
        .database_persistence = database_persistence,
        .database_compression_interval = database_compression_interval,
        .telemetry = TelemetryConfig{
            .enabled = telemetry_enabled,
            .endpoint = telemetry_endpoint,
            .service_name = telemetry_service_name orelse try allocator.dupe(u8, "ztick"),
            .flush_interval_ms = telemetry_flush_interval_ms,
        },
        .shell = ShellConfig{
            .path = shell_path orelse try allocator.dupe(u8, "/bin/sh"),
            .args = shell_args orelse try make_default_shell_args(allocator),
        },
        .http_listen = http_listen,
    };
}

fn make_default_shell_args(allocator: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
    const args = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(args);
    args[0] = try allocator.dupe(u8, "-c");
    return args;
}

fn unescape_toml_string(allocator: std.mem.Allocator, raw: []const u8) (ConfigError || std.mem.Allocator.Error)![]const u8 {
    var buf = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(buf);
    var out: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            switch (raw[i + 1]) {
                '"' => {
                    buf[out] = '"';
                    out += 1;
                    i += 2;
                },
                '\\' => {
                    buf[out] = '\\';
                    out += 1;
                    i += 2;
                },
                else => return ConfigError.InvalidValue,
            }
        } else {
            buf[out] = raw[i];
            out += 1;
            i += 1;
        }
    }
    if (out == raw.len) return buf;
    const result = try allocator.dupe(u8, buf[0..out]);
    allocator.free(buf);
    return result;
}

fn parse_toml_string_array(allocator: std.mem.Allocator, raw: []const u8) (ConfigError || std.mem.Allocator.Error)![]const []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return ConfigError.InvalidValue;
    }
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");

    var list = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < inner.len) {
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t')) pos += 1;
        if (pos >= inner.len) break;

        if (inner[pos] != '"') return ConfigError.InvalidValue;
        pos += 1;

        const str_start = pos;
        while (pos < inner.len) {
            if (inner[pos] == '\\' and pos + 1 < inner.len) {
                pos += 2;
            } else if (inner[pos] == '"') {
                break;
            } else {
                pos += 1;
            }
        }
        if (pos >= inner.len or inner[pos] != '"') return ConfigError.InvalidValue;

        const slice = inner[str_start..pos];
        const duped = try unescape_toml_string(allocator, slice);
        errdefer allocator.free(duped);
        try list.append(allocator, duped);
        pos += 1;

        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t')) pos += 1;
        if (pos >= inner.len) break;
        if (inner[pos] != ',') return ConfigError.InvalidValue;
        pos += 1;
    }

    return list.toOwnedSlice(allocator);
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
    const cfg = try parse(allocator, content);
    errdefer cfg.deinit(allocator);
    try cfg.shell.validate();
    return cfg;
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

test "tls fields default to null when not configured" {
    const cfg = try parse(std.testing.allocator, "");
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), cfg.controller_tls_cert);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.controller_tls_key);
}

test "parse sets both tls cert and key when both configured" {
    const cfg = try parse(std.testing.allocator,
        \\[controller]
        \\tls_cert = "/etc/ztick/server.crt"
        \\tls_key = "/etc/ztick/server.key"
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/etc/ztick/server.crt", cfg.controller_tls_cert.?);
    try std.testing.expectEqualStrings("/etc/ztick/server.key", cfg.controller_tls_key.?);
}

test "parse rejects config with tls cert but no tls key" {
    const result = parse(std.testing.allocator,
        \\[controller]
        \\tls_cert = "/etc/ztick/server.crt"
        \\
    );
    try std.testing.expectError(ConfigError.InvalidValue, result);
}

test "parse rejects config with tls key but no tls cert" {
    const result = parse(std.testing.allocator,
        \\[controller]
        \\tls_key = "/etc/ztick/server.key"
        \\
    );
    try std.testing.expectError(ConfigError.InvalidValue, result);
}

test "parse defaults persistence mode to logfile when key absent" {
    const cfg = try parse(std.testing.allocator, "");
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(PersistenceMode.logfile, cfg.database_persistence);
}

test "parse sets persistence mode to memory when configured" {
    const cfg = try parse(std.testing.allocator,
        \\[database]
        \\persistence = "memory"
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(PersistenceMode.memory, cfg.database_persistence);
}

test "parse sets persistence mode to logfile when explicitly configured" {
    const cfg = try parse(std.testing.allocator,
        \\[database]
        \\persistence = "logfile"
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(PersistenceMode.logfile, cfg.database_persistence);
}

test "parse rejects unrecognized persistence value" {
    const result = parse(std.testing.allocator,
        \\[database]
        \\persistence = "sqlite"
        \\
    );
    try std.testing.expectError(ConfigError.InvalidValue, result);
}

test "parse defaults compression interval to 3600 when key absent" {
    const cfg = try parse(std.testing.allocator, "");
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 3600), cfg.database_compression_interval);
}

test "parse sets compression interval from database section" {
    const cfg = try parse(std.testing.allocator,
        \\[database]
        \\compression_interval = 120
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 120), cfg.database_compression_interval);
}

test "parse accepts compression interval of zero to disable compression" {
    const cfg = try parse(std.testing.allocator,
        \\[database]
        \\compression_interval = 0
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), cfg.database_compression_interval);
}

test "parse rejects non-numeric compression interval" {
    const result = parse(std.testing.allocator,
        \\[database]
        \\compression_interval = hourly
        \\
    );
    try std.testing.expectError(ConfigError.InvalidValue, result);
}

test "parse rejects negative compression interval" {
    const result = parse(std.testing.allocator,
        \\[database]
        \\compression_interval = -1
        \\
    );
    try std.testing.expectError(ConfigError.InvalidValue, result);
}

test "parse rejects overflow compression interval" {
    const result = parse(std.testing.allocator,
        \\[database]
        \\compression_interval = 4294967296
        \\
    );
    try std.testing.expectError(ConfigError.InvalidValue, result);
}

test "telemetry defaults to disabled with ztick service name when section absent" {
    const cfg = try parse(std.testing.allocator, "");
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(false, cfg.telemetry.enabled);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.telemetry.endpoint);
    try std.testing.expectEqualStrings("ztick", cfg.telemetry.service_name);
    try std.testing.expectEqual(@as(u32, 5000), cfg.telemetry.flush_interval_ms);
}

test "parse telemetry enabled flag as true" {
    const cfg = try parse(std.testing.allocator,
        \\[telemetry]
        \\enabled = true
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(true, cfg.telemetry.enabled);
}

test "parse telemetry endpoint from section" {
    const cfg = try parse(std.testing.allocator,
        \\[telemetry]
        \\endpoint = "http://collector:4318"
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.telemetry.endpoint != null);
    try std.testing.expectEqualStrings("http://collector:4318", cfg.telemetry.endpoint.?);
}

test "parse telemetry service_name from section" {
    const cfg = try parse(std.testing.allocator,
        \\[telemetry]
        \\service_name = "my-service"
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("my-service", cfg.telemetry.service_name);
}

test "parse telemetry flush_interval_ms from section" {
    const cfg = try parse(std.testing.allocator,
        \\[telemetry]
        \\flush_interval_ms = 10000
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 10000), cfg.telemetry.flush_interval_ms);
}

test "parse rejects unknown key in telemetry section" {
    const result = parse(std.testing.allocator,
        \\[telemetry]
        \\unknown_key = true
        \\
    );
    try std.testing.expectError(ConfigError.UnknownKey, result);
}

test "shell defaults to /bin/sh with -c when section absent" {
    const cfg = try parse(std.testing.allocator, "");
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/bin/sh", cfg.shell.path);
    try std.testing.expectEqual(@as(usize, 1), cfg.shell.args.len);
    try std.testing.expectEqualStrings("-c", cfg.shell.args[0]);
}

test "parse shell path from section uses custom binary" {
    const cfg = try parse(std.testing.allocator,
        \\[shell]
        \\path = "/bin/bash"
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/bin/bash", cfg.shell.path);
    try std.testing.expectEqual(@as(usize, 1), cfg.shell.args.len);
    try std.testing.expectEqualStrings("-c", cfg.shell.args[0]);
}

test "parse shell args array overrides default" {
    const cfg = try parse(std.testing.allocator,
        \\[shell]
        \\path = "/bin/bash"
        \\args = ["-e", "-c"]
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/bin/bash", cfg.shell.path);
    try std.testing.expectEqual(@as(usize, 2), cfg.shell.args.len);
    try std.testing.expectEqualStrings("-e", cfg.shell.args[0]);
    try std.testing.expectEqualStrings("-c", cfg.shell.args[1]);
}

test "parse shell args as empty array" {
    const cfg = try parse(std.testing.allocator,
        \\[shell]
        \\path = "/bin/echo"
        \\args = []
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/bin/echo", cfg.shell.path);
    try std.testing.expectEqual(@as(usize, 0), cfg.shell.args.len);
}

test "parse rejects unknown key in shell section" {
    const result = parse(std.testing.allocator,
        \\[shell]
        \\timeout = 30
        \\
    );
    try std.testing.expectError(ConfigError.UnknownKey, result);
}

test "shell validate succeeds for existing executable path" {
    const cfg = ShellConfig{ .path = "/bin/sh", .args = &.{} };
    try cfg.validate();
}

test "shell validate returns error for nonexistent path" {
    const cfg = ShellConfig{ .path = "/nonexistent/shell/binary", .args = &.{} };
    try std.testing.expectError(ConfigError.InvalidShellPath, cfg.validate());
}

test "http listen defaults to null when section absent" {
    const cfg = try parse(std.testing.allocator, "");
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), cfg.http_listen);
}

test "parse http listen from section" {
    const cfg = try parse(std.testing.allocator,
        \\[http]
        \\listen = "127.0.0.1:5680"
        \\
    );
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("127.0.0.1:5680", cfg.http_listen.?);
}

test "parse rejects unknown key in http section" {
    const result = parse(std.testing.allocator,
        \\[http]
        \\port = 5680
        \\
    );
    try std.testing.expectError(ConfigError.UnknownKey, result);
}
