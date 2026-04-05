const std = @import("std");

pub const JsonError = error{
    MissingRequiredField,
    InvalidJson,
    InvalidTimestamp,
};

pub const JobInput = struct {
    execution: i64,
};

pub const RuleInput = struct {
    pattern: []const u8,
    runner: []const u8,
    args: []const []const u8,
};

pub const JobEntry = struct {
    id: []const u8,
    status: []const u8,
    execution: i64,
};

pub const RuleEntry = struct {
    id: []const u8,
    pattern: []const u8,
    runner: []const u8,
};

// --- Parsing ---

pub fn parse_job_body(allocator: std.mem.Allocator, body: []const u8) JsonError!JobInput {
    const Raw = struct { execution: []const u8 };
    var parsed = std.json.parseFromSlice(Raw, allocator, body, .{ .ignore_unknown_fields = true }) catch return JsonError.InvalidJson;
    defer parsed.deinit();
    const ns = parse_iso8601_to_ns(parsed.value.execution) catch return JsonError.InvalidTimestamp;
    return JobInput{ .execution = ns };
}

pub fn parse_rule_body(allocator: std.mem.Allocator, body: []const u8) (std.mem.Allocator.Error || JsonError)!RuleInput {
    const Raw = struct { pattern: []const u8, runner: []const u8, args: []const []const u8 };
    var parsed = std.json.parseFromSlice(Raw, allocator, body, .{ .ignore_unknown_fields = true }) catch return JsonError.InvalidJson;
    defer parsed.deinit();
    const pattern = try allocator.dupe(u8, parsed.value.pattern);
    errdefer allocator.free(pattern);
    const runner = try allocator.dupe(u8, parsed.value.runner);
    errdefer allocator.free(runner);
    var args = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (args.items) |a| allocator.free(a);
        args.deinit(allocator);
    }
    for (parsed.value.args) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }
    return RuleInput{ .pattern = pattern, .runner = runner, .args = try args.toOwnedSlice(allocator) };
}

// --- Serialization ---

pub fn serialize_job(allocator: std.mem.Allocator, id: []const u8, status: []const u8, execution_ns: i64) std.mem.Allocator.Error![]u8 {
    return stringify(allocator, JobEntry{ .id = id, .status = status, .execution = execution_ns });
}

pub fn serialize_rule(allocator: std.mem.Allocator, id: []const u8, pattern: []const u8, runner_type: []const u8) std.mem.Allocator.Error![]u8 {
    return stringify(allocator, RuleEntry{ .id = id, .pattern = pattern, .runner = runner_type });
}

pub fn serialize_jobs_array(allocator: std.mem.Allocator, jobs: []const JobEntry) std.mem.Allocator.Error![]u8 {
    return stringify(allocator, jobs);
}

pub fn serialize_rules_array(allocator: std.mem.Allocator, rules: []const RuleEntry) std.mem.Allocator.Error![]u8 {
    return stringify(allocator, rules);
}

pub fn serialize_error(allocator: std.mem.Allocator, message: []const u8) std.mem.Allocator.Error![]u8 {
    return stringify(allocator, .{ .@"error" = message });
}

pub fn serialize_health(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return stringify(allocator, .{ .status = "ok" });
}

fn stringify(allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    s.write(value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// --- ISO 8601 ---

pub fn parse_iso8601_to_ns(timestamp: []const u8) JsonError!i64 {
    if (timestamp.len < 20) return JsonError.InvalidTimestamp;

    const year = std.fmt.parseInt(u16, timestamp[0..4], 10) catch return JsonError.InvalidTimestamp;
    if (timestamp[4] != '-') return JsonError.InvalidTimestamp;
    const month = std.fmt.parseInt(u8, timestamp[5..7], 10) catch return JsonError.InvalidTimestamp;
    if (timestamp[7] != '-') return JsonError.InvalidTimestamp;
    const day = std.fmt.parseInt(u8, timestamp[8..10], 10) catch return JsonError.InvalidTimestamp;
    if (timestamp[10] != 'T') return JsonError.InvalidTimestamp;
    const hour = std.fmt.parseInt(u8, timestamp[11..13], 10) catch return JsonError.InvalidTimestamp;
    if (timestamp[13] != ':') return JsonError.InvalidTimestamp;
    const minute = std.fmt.parseInt(u8, timestamp[14..16], 10) catch return JsonError.InvalidTimestamp;
    if (timestamp[16] != ':') return JsonError.InvalidTimestamp;
    const second = std.fmt.parseInt(u8, timestamp[17..19], 10) catch return JsonError.InvalidTimestamp;

    const epoch_seconds = toEpochSeconds(year, month, day, hour, minute, second) catch return JsonError.InvalidTimestamp;
    return epoch_seconds * std.time.ns_per_s;
}

fn toEpochSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) error{InvalidDate}!i64 {
    if (month < 1 or month > 12) return error.InvalidDate;
    if (day < 1 or day > 31) return error.InvalidDate;

    const days_per_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = isLeapYear(year);

    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) 366 else 365;
    }
    for (0..month - 1) |m| {
        const month_days: u8 = if (m == 1 and leap) 29 else days_per_month[m];
        days += month_days;
    }
    days += @as(i64, day) - 1;

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

// --- Tests ---

test "parse_job_body parses ISO 8601 execution timestamp" {
    const body = "{\"execution\":\"2026-04-10T12:00:00Z\"}";
    const result = try parse_job_body(std.testing.allocator, body);
    try std.testing.expectEqual(@as(i64, 1775822400000000000), result.execution);
}

test "parse_job_body returns InvalidJson when execution is absent" {
    const body = "{\"other\":\"value\"}";
    try std.testing.expectError(JsonError.InvalidJson, parse_job_body(std.testing.allocator, body));
}

test "parse_rule_body parses pattern runner and args fields" {
    const body = "{\"pattern\":\"deploy.*\",\"runner\":\"shell\",\"args\":[\"/usr/bin/notify\",\"--channel\",\"ops\"]}";
    const result = try parse_rule_body(std.testing.allocator, body);
    defer std.testing.allocator.free(result.pattern);
    defer std.testing.allocator.free(result.runner);
    for (result.args) |arg| std.testing.allocator.free(arg);
    defer std.testing.allocator.free(result.args);
    try std.testing.expectEqualStrings("deploy.*", result.pattern);
    try std.testing.expectEqualStrings("shell", result.runner);
    try std.testing.expectEqual(@as(usize, 3), result.args.len);
}

test "parse_rule_body returns InvalidJson when pattern is absent" {
    const body = "{\"runner\":\"shell\",\"args\":[]}";
    try std.testing.expectError(JsonError.InvalidJson, parse_rule_body(std.testing.allocator, body));
}

test "serialize_jobs_array produces JSON array for non-empty input" {
    const jobs = [_]JobEntry{
        .{ .id = "deploy.v1", .status = "planned", .execution = 1744286400000000000 },
    };
    const result = try serialize_jobs_array(std.testing.allocator, &jobs);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[{\"id\":\"deploy.v1\",\"status\":\"planned\",\"execution\":1744286400000000000}]", result);
}

test "serialize_rules_array produces JSON array for non-empty input" {
    const rules = [_]RuleEntry{
        .{ .id = "notify", .pattern = "deploy.*", .runner = "shell" },
    };
    const result = try serialize_rules_array(std.testing.allocator, &rules);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[{\"id\":\"notify\",\"pattern\":\"deploy.*\",\"runner\":\"shell\"}]", result);
}

test "serialize_job produces JSON with id status and execution fields" {
    const result = try serialize_job(std.testing.allocator, "deploy.v1", "planned", 1744286400000000000);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"id\":\"deploy.v1\",\"status\":\"planned\",\"execution\":1744286400000000000}", result);
}

test "serialize_rule produces JSON with id pattern and runner fields" {
    const result = try serialize_rule(std.testing.allocator, "notify", "deploy.*", "shell");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"id\":\"notify\",\"pattern\":\"deploy.*\",\"runner\":\"shell\"}", result);
}

test "serialize_error produces JSON with error field" {
    const result = try serialize_error(std.testing.allocator, "not found");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", result);
}

test "serialize_health produces JSON with status ok" {
    const result = try serialize_health(std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", result);
}
