const std = @import("std");
const domain = @import("../../domain.zig");

pub const DecodeError = error{InvalidData};

/// Persisted entry types. GET and QUERY instructions are read-only and skipped at the
/// persistence layer, so no encoder variant is needed.
pub const Entry = union(enum) {
    job: domain.job.Job,
    rule: domain.rule.Rule,
    job_removal: struct { identifier: []const u8 },
    rule_removal: struct { identifier: []const u8 },
};

pub fn encode(allocator: std.mem.Allocator, value: Entry) ![]u8 {
    return switch (value) {
        .job => |job| encode_job(allocator, job),
        .rule => |rule| encode_rule(allocator, rule),
        .job_removal => |r| encode_removal(allocator, 2, r.identifier),
        .rule_removal => |r| encode_removal(allocator, 3, r.identifier),
    };
}

pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!Entry {
    return decode_inner(allocator, data) catch DecodeError.InvalidData;
}

fn encode_job(allocator: std.mem.Allocator, job: domain.job.Job) ![]u8 {
    const id_len = job.identifier.len;
    if (id_len > std.math.maxInt(u16)) return error.Overflow;

    const result = try allocator.alloc(u8, 12 + id_len);
    result[0] = 0;
    std.mem.writeInt(u16, result[1..3], @intCast(id_len), .big);
    @memcpy(result[3 .. 3 + id_len], job.identifier);
    std.mem.writeInt(i64, result[3 + id_len ..][0..8], job.execution, .big);
    result[11 + id_len] = switch (job.status) {
        .planned => 0,
        .triggered => 1,
        .executed => 2,
        .failed => 3,
    };
    return result;
}

fn encode_rule(allocator: std.mem.Allocator, rule: domain.rule.Rule) ![]u8 {
    const id_len = rule.identifier.len;
    const pat_len = rule.pattern.len;
    if (id_len > std.math.maxInt(u16)) return error.Overflow;
    if (pat_len > std.math.maxInt(u16)) return error.Overflow;

    const runner_size = try runner_encoded_size(rule.runner);
    const total = 1 + 2 + id_len + 2 + pat_len + runner_size;

    const result = try allocator.alloc(u8, total);
    result[0] = 1;
    std.mem.writeInt(u16, result[1..3], @intCast(id_len), .big);
    @memcpy(result[3 .. 3 + id_len], rule.identifier);
    var pos: usize = 3 + id_len;
    std.mem.writeInt(u16, result[pos..][0..2], @intCast(pat_len), .big);
    pos += 2;
    @memcpy(result[pos .. pos + pat_len], rule.pattern);
    pos += pat_len;
    encode_runner(rule.runner, result[pos..]);
    return result;
}

fn runner_encoded_size(runner: domain.runner.Runner) !usize {
    return switch (runner) {
        .shell => |s| blk: {
            if (s.command.len > std.math.maxInt(u16)) return error.Overflow;
            break :blk 1 + 2 + s.command.len;
        },
        .amqp => |a| blk: {
            if (a.dsn.len > std.math.maxInt(u16)) return error.Overflow;
            if (a.exchange.len > std.math.maxInt(u16)) return error.Overflow;
            if (a.routing_key.len > std.math.maxInt(u16)) return error.Overflow;
            break :blk 1 + 2 + a.dsn.len + 2 + a.exchange.len + 2 + a.routing_key.len;
        },
        .direct => |d| blk: {
            if (d.executable.len > std.math.maxInt(u16)) return error.Overflow;
            var size: usize = 1 + 2 + d.executable.len + 2;
            for (d.args) |arg| {
                if (arg.len > std.math.maxInt(u16)) return error.Overflow;
                size += 2 + arg.len;
            }
            break :blk size;
        },
        .awf => |awf| blk: {
            if (awf.workflow.len > std.math.maxInt(u16)) return error.Overflow;
            var size: usize = 1 + 2 + awf.workflow.len + 2;
            for (awf.inputs) |input| {
                if (input.len > std.math.maxInt(u16)) return error.Overflow;
                size += 2 + input.len;
            }
            break :blk size;
        },
        .http => |h| blk: {
            if (h.method.len > std.math.maxInt(u16)) return error.Overflow;
            if (h.url.len > std.math.maxInt(u16)) return error.Overflow;
            break :blk 1 + 2 + h.method.len + 2 + h.url.len;
        },
    };
}

fn encode_runner(runner: domain.runner.Runner, buf: []u8) void {
    var pos: usize = 0;
    switch (runner) {
        .shell => |s| {
            buf[pos] = 0;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(s.command.len), .big);
            pos += 2;
            @memcpy(buf[pos .. pos + s.command.len], s.command);
        },
        .amqp => |a| {
            buf[pos] = 1;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(a.dsn.len), .big);
            pos += 2;
            @memcpy(buf[pos .. pos + a.dsn.len], a.dsn);
            pos += a.dsn.len;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(a.exchange.len), .big);
            pos += 2;
            @memcpy(buf[pos .. pos + a.exchange.len], a.exchange);
            pos += a.exchange.len;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(a.routing_key.len), .big);
            pos += 2;
            @memcpy(buf[pos..], a.routing_key);
        },
        .direct => |d| {
            buf[pos] = 2;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(d.executable.len), .big);
            pos += 2;
            @memcpy(buf[pos .. pos + d.executable.len], d.executable);
            pos += d.executable.len;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(d.args.len), .big);
            pos += 2;
            for (d.args) |arg| {
                std.mem.writeInt(u16, buf[pos..][0..2], @intCast(arg.len), .big);
                pos += 2;
                @memcpy(buf[pos .. pos + arg.len], arg);
                pos += arg.len;
            }
        },
        .awf => |awf| {
            buf[pos] = 3;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(awf.workflow.len), .big);
            pos += 2;
            @memcpy(buf[pos .. pos + awf.workflow.len], awf.workflow);
            pos += awf.workflow.len;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(awf.inputs.len), .big);
            pos += 2;
            for (awf.inputs) |input| {
                std.mem.writeInt(u16, buf[pos..][0..2], @intCast(input.len), .big);
                pos += 2;
                @memcpy(buf[pos .. pos + input.len], input);
                pos += input.len;
            }
        },
        .http => |h| {
            buf[pos] = 4;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(h.method.len), .big);
            pos += 2;
            @memcpy(buf[pos .. pos + h.method.len], h.method);
            pos += h.method.len;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(h.url.len), .big);
            pos += 2;
            @memcpy(buf[pos..], h.url);
        },
    }
}

fn encode_removal(allocator: std.mem.Allocator, type_byte: u8, identifier: []const u8) ![]u8 {
    if (identifier.len > std.math.maxInt(u16)) return error.Overflow;
    const result = try allocator.alloc(u8, 1 + 2 + identifier.len);
    result[0] = type_byte;
    std.mem.writeInt(u16, result[1..3], @intCast(identifier.len), .big);
    @memcpy(result[3..], identifier);
    return result;
}

fn decode_inner(allocator: std.mem.Allocator, data: []const u8) !Entry {
    var pos: usize = 0;

    if (data.len == 0) return error.InvalidData;

    const type_byte = data[pos];
    pos += 1;

    switch (type_byte) {
        0 => {
            const id_slice = try read_sized_string(data, &pos);
            if (pos + 8 > data.len) return error.InvalidData;
            const timestamp = std.mem.readInt(i64, data[pos..][0..8], .big);
            pos += 8;
            if (pos >= data.len) return error.InvalidData;
            const status_byte = data[pos];
            pos += 1;
            if (pos != data.len) return error.InvalidData;
            const status: domain.job.JobStatus = switch (status_byte) {
                0 => .planned,
                1 => .triggered,
                2 => .executed,
                3 => .failed,
                else => return error.InvalidData,
            };
            const id_copy = try allocator.dupe(u8, id_slice);
            return .{ .job = .{ .identifier = id_copy, .execution = timestamp, .status = status } };
        },
        1 => {
            const id_slice = try read_sized_string(data, &pos);
            const pat_slice = try read_sized_string(data, &pos);
            if (pos >= data.len) return error.InvalidData;
            const runner_type = data[pos];
            pos += 1;

            switch (runner_type) {
                0 => {
                    const cmd_slice = try read_sized_string(data, &pos);
                    if (pos != data.len) return error.InvalidData;
                    const id_copy = try allocator.dupe(u8, id_slice);
                    errdefer allocator.free(id_copy);
                    const pat_copy = try allocator.dupe(u8, pat_slice);
                    errdefer allocator.free(pat_copy);
                    const cmd_copy = try allocator.dupe(u8, cmd_slice);
                    return .{ .rule = .{
                        .identifier = id_copy,
                        .pattern = pat_copy,
                        .runner = .{ .shell = .{ .command = cmd_copy } },
                    } };
                },
                1 => {
                    const dsn_slice = try read_sized_string(data, &pos);
                    const exch_slice = try read_sized_string(data, &pos);
                    const rk_slice = try read_sized_string(data, &pos);
                    if (pos != data.len) return error.InvalidData;
                    const id_copy = try allocator.dupe(u8, id_slice);
                    errdefer allocator.free(id_copy);
                    const pat_copy = try allocator.dupe(u8, pat_slice);
                    errdefer allocator.free(pat_copy);
                    const dsn_copy = try allocator.dupe(u8, dsn_slice);
                    errdefer allocator.free(dsn_copy);
                    const exch_copy = try allocator.dupe(u8, exch_slice);
                    errdefer allocator.free(exch_copy);
                    const rk_copy = try allocator.dupe(u8, rk_slice);
                    return .{ .rule = .{
                        .identifier = id_copy,
                        .pattern = pat_copy,
                        .runner = .{ .amqp = .{ .dsn = dsn_copy, .exchange = exch_copy, .routing_key = rk_copy } },
                    } };
                },
                2 => {
                    const exe_slice = try read_sized_string(data, &pos);
                    if (pos + 2 > data.len) return error.InvalidData;
                    const argc = std.mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2;
                    const id_copy = try allocator.dupe(u8, id_slice);
                    errdefer allocator.free(id_copy);
                    const pat_copy = try allocator.dupe(u8, pat_slice);
                    errdefer allocator.free(pat_copy);
                    const exe_copy = try allocator.dupe(u8, exe_slice);
                    errdefer allocator.free(exe_copy);
                    const args = try allocator.alloc([]const u8, argc);
                    var args_filled: usize = 0;
                    errdefer {
                        for (args[0..args_filled]) |arg| allocator.free(arg);
                        allocator.free(args);
                    }
                    for (args) |*arg| {
                        const arg_slice = try read_sized_string(data, &pos);
                        arg.* = try allocator.dupe(u8, arg_slice);
                        args_filled += 1;
                    }
                    if (pos != data.len) return error.InvalidData;
                    return .{ .rule = .{
                        .identifier = id_copy,
                        .pattern = pat_copy,
                        .runner = .{ .direct = .{ .executable = exe_copy, .args = args } },
                    } };
                },
                3 => {
                    const wf_slice = try read_sized_string(data, &pos);
                    if (pos + 2 > data.len) return error.InvalidData;
                    const input_count = std.mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2;
                    const id_copy = try allocator.dupe(u8, id_slice);
                    errdefer allocator.free(id_copy);
                    const pat_copy = try allocator.dupe(u8, pat_slice);
                    errdefer allocator.free(pat_copy);
                    const wf_copy = try allocator.dupe(u8, wf_slice);
                    errdefer allocator.free(wf_copy);
                    const inputs = try allocator.alloc([]const u8, input_count);
                    var inputs_filled: usize = 0;
                    errdefer {
                        for (inputs[0..inputs_filled]) |input| allocator.free(input);
                        allocator.free(inputs);
                    }
                    for (inputs) |*input| {
                        const input_slice = try read_sized_string(data, &pos);
                        input.* = try allocator.dupe(u8, input_slice);
                        inputs_filled += 1;
                    }
                    if (pos != data.len) return error.InvalidData;
                    return .{ .rule = .{
                        .identifier = id_copy,
                        .pattern = pat_copy,
                        .runner = .{ .awf = .{ .workflow = wf_copy, .inputs = inputs } },
                    } };
                },
                4 => {
                    const method_slice = try read_sized_string(data, &pos);
                    const url_slice = try read_sized_string(data, &pos);
                    if (pos != data.len) return error.InvalidData;
                    const id_copy = try allocator.dupe(u8, id_slice);
                    errdefer allocator.free(id_copy);
                    const pat_copy = try allocator.dupe(u8, pat_slice);
                    errdefer allocator.free(pat_copy);
                    const method_copy = try allocator.dupe(u8, method_slice);
                    errdefer allocator.free(method_copy);
                    const url_copy = try allocator.dupe(u8, url_slice);
                    return .{ .rule = .{
                        .identifier = id_copy,
                        .pattern = pat_copy,
                        .runner = .{ .http = .{ .method = method_copy, .url = url_copy } },
                    } };
                },
                else => return error.InvalidData,
            }
        },
        2 => {
            const id_slice = try read_sized_string(data, &pos);
            if (pos != data.len) return error.InvalidData;
            const id_copy = try allocator.dupe(u8, id_slice);
            return .{ .job_removal = .{ .identifier = id_copy } };
        },
        3 => {
            const id_slice = try read_sized_string(data, &pos);
            if (pos != data.len) return error.InvalidData;
            const id_copy = try allocator.dupe(u8, id_slice);
            return .{ .rule_removal = .{ .identifier = id_copy } };
        },
        else => return error.InvalidData,
    }
}

fn read_sized_string(data: []const u8, pos: *usize) ![]const u8 {
    if (pos.* + 2 > data.len) return error.InvalidData;
    const len = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    if (pos.* + len > data.len) return error.InvalidData;
    const s = data[pos.* .. pos.* + len];
    pos.* += len;
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidData;
    return s;
}

/// Frees heap-allocated fields of a decoded Entry beyond the identifier.
/// For job and removal entries this is a no-op (job fields are value types;
/// removal entries contain only an identifier). For rule entries, frees the
/// pattern and runner strings. The identifier is left for the caller to free.
pub fn free_entry_fields(entry: Entry, allocator: std.mem.Allocator) void {
    switch (entry) {
        .job => {},
        .rule => |r| {
            allocator.free(r.pattern);
            switch (r.runner) {
                .shell => |s| allocator.free(s.command),
                .amqp => |a| {
                    allocator.free(a.dsn);
                    allocator.free(a.exchange);
                    allocator.free(a.routing_key);
                },
                .direct => |d| {
                    allocator.free(d.executable);
                    for (d.args) |arg| allocator.free(arg);
                    allocator.free(d.args);
                },
                .awf => |awf| {
                    allocator.free(awf.workflow);
                    for (awf.inputs) |input| allocator.free(input);
                    allocator.free(awf.inputs);
                },
                .http => |h| {
                    allocator.free(h.method);
                    allocator.free(h.url);
                },
            }
        },
        .job_removal => {},
        .rule_removal => {},
    }
}

// Timestamp for 2020-11-15T16:30:00Z in nanoseconds (used across encode/decode tests).
const ts_2020_11_15_16_30_00: i64 = 1605457800_000000000;

test "encode job planned" {
    const job = domain.job.Job{ .identifier = "toto", .execution = ts_2020_11_15_16_30_00, .status = .planned };
    const result = try encode(std.testing.allocator, .{ .job = job });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 4, 116, 111, 116, 111, 22, 71, 187, 92, 238, 225, 80, 0, 0 }, result);
}

test "encode job executed" {
    const job = domain.job.Job{ .identifier = "tatat", .execution = ts_2020_11_15_16_30_00, .status = .executed };
    const result = try encode(std.testing.allocator, .{ .job = job });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 5, 116, 97, 116, 97, 116, 22, 71, 187, 92, 238, 225, 80, 0, 2 }, result);
}

test "encode rule shell runner" {
    const rule = domain.rule.Rule{
        .identifier = "t",
        .pattern = "toto",
        .runner = .{ .shell = .{ .command = "titi" } },
    };
    const result = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 116, 0, 4, 116, 111, 116, 111, 0, 0, 4, 116, 105, 116, 105 }, result);
}

test "encode rule amqp runner" {
    const rule = domain.rule.Rule{
        .identifier = "ta",
        .pattern = "tot",
        .runner = .{ .amqp = .{ .dsn = "titit", .exchange = "", .routing_key = "a" } },
    };
    const result = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 2, 116, 97, 0, 3, 116, 111, 116, 1, 0, 5, 116, 105, 116, 105, 116, 0, 0, 0, 1, 97 }, result);
}

test "decode job planned" {
    const data = [_]u8{ 0, 0, 4, 116, 111, 116, 111, 22, 71, 187, 92, 238, 225, 80, 0, 0 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.job.identifier);
    try std.testing.expectEqualStrings("toto", result.job.identifier);
    try std.testing.expectEqual(ts_2020_11_15_16_30_00, result.job.execution);
    try std.testing.expectEqual(domain.job.JobStatus.planned, result.job.status);
}

test "decode job executed" {
    const data = [_]u8{ 0, 0, 5, 116, 97, 116, 97, 116, 22, 71, 187, 92, 238, 225, 80, 0, 2 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.job.identifier);
    try std.testing.expectEqualStrings("tatat", result.job.identifier);
    try std.testing.expectEqual(ts_2020_11_15_16_30_00, result.job.execution);
    try std.testing.expectEqual(domain.job.JobStatus.executed, result.job.status);
}

test "decode rule shell runner" {
    const data = [_]u8{ 1, 0, 1, 116, 0, 4, 116, 111, 116, 111, 0, 0, 4, 116, 105, 116, 105 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.rule.identifier);
    defer std.testing.allocator.free(result.rule.pattern);
    defer std.testing.allocator.free(result.rule.runner.shell.command);
    try std.testing.expectEqualStrings("t", result.rule.identifier);
    try std.testing.expectEqualStrings("toto", result.rule.pattern);
    try std.testing.expectEqualStrings("titi", result.rule.runner.shell.command);
}

test "decode rule amqp runner" {
    const data = [_]u8{ 1, 0, 2, 116, 97, 0, 3, 116, 111, 116, 1, 0, 5, 116, 105, 116, 105, 116, 0, 0, 0, 1, 97 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.rule.identifier);
    defer std.testing.allocator.free(result.rule.pattern);
    defer std.testing.allocator.free(result.rule.runner.amqp.dsn);
    defer std.testing.allocator.free(result.rule.runner.amqp.exchange);
    defer std.testing.allocator.free(result.rule.runner.amqp.routing_key);
    try std.testing.expectEqualStrings("ta", result.rule.identifier);
    try std.testing.expectEqualStrings("tot", result.rule.pattern);
    try std.testing.expectEqualStrings("titit", result.rule.runner.amqp.dsn);
    try std.testing.expectEqualStrings("", result.rule.runner.amqp.exchange);
    try std.testing.expectEqualStrings("a", result.rule.runner.amqp.routing_key);
}

test "decode error on empty buffer" {
    try std.testing.expectError(DecodeError.InvalidData, decode(std.testing.allocator, &[_]u8{}));
}

test "decode error on truncated buffer" {
    try std.testing.expectError(DecodeError.InvalidData, decode(std.testing.allocator, &[_]u8{ 0, 0, 4 }));
}

test "decode error on trailing bytes" {
    const data = [_]u8{ 0, 0, 4, 116, 111, 116, 111, 22, 71, 187, 92, 238, 225, 80, 0, 0, 255 };
    try std.testing.expectError(DecodeError.InvalidData, decode(std.testing.allocator, &data));
}

test "encode job removal" {
    const result = try encode(std.testing.allocator, .{ .job_removal = .{ .identifier = "foo" } });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 0, 3, 102, 111, 111 }, result);
}

test "encode rule removal" {
    const result = try encode(std.testing.allocator, .{ .rule_removal = .{ .identifier = "bar" } });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 0, 3, 98, 97, 114 }, result);
}

test "decode job removal" {
    const data = [_]u8{ 2, 0, 3, 102, 111, 111 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.job_removal.identifier);
    try std.testing.expectEqualStrings("foo", result.job_removal.identifier);
}

test "decode rule removal" {
    const data = [_]u8{ 3, 0, 3, 98, 97, 114 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.rule_removal.identifier);
    try std.testing.expectEqualStrings("bar", result.rule_removal.identifier);
}

test "decode error on trailing bytes after job removal" {
    const data = [_]u8{ 2, 0, 3, 102, 111, 111, 255 };
    try std.testing.expectError(DecodeError.InvalidData, decode(std.testing.allocator, &data));
}

test "encode rule direct runner no args" {
    const rule = domain.rule.Rule{
        .identifier = "a",
        .pattern = "b",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &[_][]const u8{} } },
    };
    const result = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(result);
    // type=1, id=[0,1,'a'], pat=[0,1,'b'], runner_type=2, exe=[0,9,"/bin/true"], argc=[0,0]
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 97, 0, 1, 98, 2, 0, 9, 47, 98, 105, 110, 47, 116, 114, 117, 101, 0, 0 }, result);
}

test "encode rule direct runner with args" {
    const args = [_][]const u8{"hi"};
    const rule = domain.rule.Rule{
        .identifier = "a",
        .pattern = "b",
        .runner = .{ .direct = .{ .executable = "/bin/echo", .args = &args } },
    };
    const result = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(result);
    // type=1, id=[0,1,'a'], pat=[0,1,'b'], runner_type=2, exe=[0,9,"/bin/echo"], argc=[0,1], arg=[0,2,"hi"]
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 97, 0, 1, 98, 2, 0, 9, 47, 98, 105, 110, 47, 101, 99, 104, 111, 0, 1, 0, 2, 104, 105 }, result);
}

test "decode rule direct runner no args" {
    const data = [_]u8{ 1, 0, 1, 97, 0, 1, 98, 2, 0, 9, 47, 98, 105, 110, 47, 116, 114, 117, 101, 0, 0 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.rule.identifier);
    defer std.testing.allocator.free(result.rule.pattern);
    defer std.testing.allocator.free(result.rule.runner.direct.executable);
    defer std.testing.allocator.free(result.rule.runner.direct.args);
    try std.testing.expectEqualStrings("a", result.rule.identifier);
    try std.testing.expectEqualStrings("b", result.rule.pattern);
    try std.testing.expectEqualStrings("/bin/true", result.rule.runner.direct.executable);
    try std.testing.expectEqual(@as(usize, 0), result.rule.runner.direct.args.len);
}

test "decode rule direct runner with args" {
    const data = [_]u8{ 1, 0, 1, 97, 0, 1, 98, 2, 0, 9, 47, 98, 105, 110, 47, 101, 99, 104, 111, 0, 1, 0, 2, 104, 105 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.rule.identifier);
    defer std.testing.allocator.free(result.rule.pattern);
    defer std.testing.allocator.free(result.rule.runner.direct.executable);
    defer {
        for (result.rule.runner.direct.args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(result.rule.runner.direct.args);
    }
    try std.testing.expectEqualStrings("a", result.rule.identifier);
    try std.testing.expectEqualStrings("b", result.rule.pattern);
    try std.testing.expectEqualStrings("/bin/echo", result.rule.runner.direct.executable);
    try std.testing.expectEqual(@as(usize, 1), result.rule.runner.direct.args.len);
    try std.testing.expectEqualStrings("hi", result.rule.runner.direct.args[0]);
}

test "free_entry_fields frees direct runner rule fields without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule1");
    const pattern = try allocator.dupe(u8, "exec.*");
    const executable = try allocator.dupe(u8, "/bin/echo");
    const args = try allocator.alloc([]const u8, 0);
    const entry = Entry{ .rule = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .direct = .{ .executable = executable, .args = args } },
    } };
    free_entry_fields(entry, allocator);
    allocator.free(id);
}

test "free_entry_fields frees direct runner rule fields with args without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule2");
    const pattern = try allocator.dupe(u8, "log.*");
    const executable = try allocator.dupe(u8, "/usr/bin/cmd");
    const args = try allocator.alloc([]const u8, 2);
    args[0] = try allocator.dupe(u8, "--flag");
    args[1] = try allocator.dupe(u8, "value");
    const entry = Entry{ .rule = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .direct = .{ .executable = executable, .args = args } },
    } };
    free_entry_fields(entry, allocator);
    allocator.free(id);
}

test "encode rule awf runner without inputs" {
    const rule = domain.rule.Rule{
        .identifier = "a",
        .pattern = "b",
        .runner = .{ .awf = .{ .workflow = "hello", .inputs = &.{} } },
    };
    const result = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(result);
    // type=1, id=[0,1,'a'], pat=[0,1,'b'], runner_type=3, wf=[0,5,"hello"], input_count=[0,0]
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 97, 0, 1, 98, 3, 0, 5, 104, 101, 108, 108, 111, 0, 0 }, result);
}

test "encode rule awf runner with inputs" {
    const inputs = [_][]const u8{ "format=pdf", "target=main" };
    const rule = domain.rule.Rule{
        .identifier = "a",
        .pattern = "b",
        .runner = .{ .awf = .{ .workflow = "hello", .inputs = &inputs } },
    };
    const result = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(result);
    // type=1, id=[0,1,'a'], pat=[0,1,'b'], runner_type=3, wf=[0,5,"hello"], count=[0,2], [0,10,"format=pdf"], [0,11,"target=main"]
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 97, 0, 1, 98, 3, 0, 5, 104, 101, 108, 108, 111, 0, 2, 0, 10, 102, 111, 114, 109, 97, 116, 61, 112, 100, 102, 0, 11, 116, 97, 114, 103, 101, 116, 61, 109, 97, 105, 110 }, result);
}

test "decode rule awf runner without inputs" {
    const data = [_]u8{ 1, 0, 1, 97, 0, 1, 98, 3, 0, 5, 104, 101, 108, 108, 111, 0, 0 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.rule.identifier);
    defer std.testing.allocator.free(result.rule.pattern);
    defer std.testing.allocator.free(result.rule.runner.awf.workflow);
    defer std.testing.allocator.free(result.rule.runner.awf.inputs);
    try std.testing.expectEqualStrings("a", result.rule.identifier);
    try std.testing.expectEqualStrings("b", result.rule.pattern);
    try std.testing.expectEqualStrings("hello", result.rule.runner.awf.workflow);
    try std.testing.expectEqual(@as(usize, 0), result.rule.runner.awf.inputs.len);
}

test "decode rule awf runner with inputs" {
    const data = [_]u8{ 1, 0, 1, 97, 0, 1, 98, 3, 0, 5, 104, 101, 108, 108, 111, 0, 2, 0, 10, 102, 111, 114, 109, 97, 116, 61, 112, 100, 102, 0, 11, 116, 97, 114, 103, 101, 116, 61, 109, 97, 105, 110 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.rule.identifier);
    defer std.testing.allocator.free(result.rule.pattern);
    defer std.testing.allocator.free(result.rule.runner.awf.workflow);
    defer {
        for (result.rule.runner.awf.inputs) |input| std.testing.allocator.free(input);
        std.testing.allocator.free(result.rule.runner.awf.inputs);
    }
    try std.testing.expectEqualStrings("a", result.rule.identifier);
    try std.testing.expectEqualStrings("b", result.rule.pattern);
    try std.testing.expectEqualStrings("hello", result.rule.runner.awf.workflow);
    try std.testing.expectEqual(@as(usize, 2), result.rule.runner.awf.inputs.len);
    try std.testing.expectEqualStrings("format=pdf", result.rule.runner.awf.inputs[0]);
    try std.testing.expectEqualStrings("target=main", result.rule.runner.awf.inputs[1]);
}

test "encode decode awf runner round trip without inputs" {
    const rule = domain.rule.Rule{
        .identifier = "rule.review",
        .pattern = "app.*",
        .runner = .{ .awf = .{ .workflow = "code-review", .inputs = &.{} } },
    };
    const encoded = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(encoded);
    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded.rule.identifier);
    defer std.testing.allocator.free(decoded.rule.pattern);
    defer std.testing.allocator.free(decoded.rule.runner.awf.workflow);
    defer std.testing.allocator.free(decoded.rule.runner.awf.inputs);
    try std.testing.expectEqualStrings("rule.review", decoded.rule.identifier);
    try std.testing.expectEqualStrings("app.*", decoded.rule.pattern);
    try std.testing.expectEqualStrings("code-review", decoded.rule.runner.awf.workflow);
    try std.testing.expectEqual(@as(usize, 0), decoded.rule.runner.awf.inputs.len);
}

test "encode decode awf runner round trip with inputs" {
    const inputs = [_][]const u8{ "format=pdf", "target=main" };
    const rule = domain.rule.Rule{
        .identifier = "rule.report",
        .pattern = "report.*",
        .runner = .{ .awf = .{ .workflow = "generate-report", .inputs = &inputs } },
    };
    const encoded = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(encoded);
    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded.rule.identifier);
    defer std.testing.allocator.free(decoded.rule.pattern);
    defer std.testing.allocator.free(decoded.rule.runner.awf.workflow);
    defer {
        for (decoded.rule.runner.awf.inputs) |input| std.testing.allocator.free(input);
        std.testing.allocator.free(decoded.rule.runner.awf.inputs);
    }
    try std.testing.expectEqualStrings("rule.report", decoded.rule.identifier);
    try std.testing.expectEqualStrings("report.*", decoded.rule.pattern);
    try std.testing.expectEqualStrings("generate-report", decoded.rule.runner.awf.workflow);
    try std.testing.expectEqual(@as(usize, 2), decoded.rule.runner.awf.inputs.len);
    try std.testing.expectEqualStrings("format=pdf", decoded.rule.runner.awf.inputs[0]);
    try std.testing.expectEqualStrings("target=main", decoded.rule.runner.awf.inputs[1]);
}

test "encode rule http runner" {
    const rule = domain.rule.Rule{
        .identifier = "a",
        .pattern = "b",
        .runner = .{ .http = .{ .method = "GET", .url = "http://x" } },
    };
    const result = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(result);
    // type=1, id=[0,1,'a'], pat=[0,1,'b'], runner_type=4, method=[0,3,"GET"], url=[0,8,"http://x"]
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 97, 0, 1, 98, 4, 0, 3, 71, 69, 84, 0, 8, 104, 116, 116, 112, 58, 47, 47, 120 }, result);
}

test "decode rule http runner" {
    const data = [_]u8{ 1, 0, 1, 97, 0, 1, 98, 4, 0, 3, 71, 69, 84, 0, 8, 104, 116, 116, 112, 58, 47, 47, 120 };
    const result = try decode(std.testing.allocator, &data);
    defer std.testing.allocator.free(result.rule.identifier);
    defer std.testing.allocator.free(result.rule.pattern);
    defer std.testing.allocator.free(result.rule.runner.http.method);
    defer std.testing.allocator.free(result.rule.runner.http.url);
    try std.testing.expectEqualStrings("a", result.rule.identifier);
    try std.testing.expectEqualStrings("b", result.rule.pattern);
    try std.testing.expectEqualStrings("GET", result.rule.runner.http.method);
    try std.testing.expectEqualStrings("http://x", result.rule.runner.http.url);
}

test "encode decode http runner round trip" {
    const rule = domain.rule.Rule{
        .identifier = "rule.notify",
        .pattern = "deploy.*",
        .runner = .{ .http = .{ .method = "POST", .url = "https://hooks.example.com/webhook" } },
    };
    const encoded = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(encoded);
    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded.rule.identifier);
    defer std.testing.allocator.free(decoded.rule.pattern);
    defer std.testing.allocator.free(decoded.rule.runner.http.method);
    defer std.testing.allocator.free(decoded.rule.runner.http.url);
    try std.testing.expectEqualStrings("rule.notify", decoded.rule.identifier);
    try std.testing.expectEqualStrings("deploy.*", decoded.rule.pattern);
    try std.testing.expectEqualStrings("POST", decoded.rule.runner.http.method);
    try std.testing.expectEqualStrings("https://hooks.example.com/webhook", decoded.rule.runner.http.url);
}

test "free_entry_fields frees http runner rule fields without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule.notify");
    const pattern = try allocator.dupe(u8, "deploy.*");
    const method = try allocator.dupe(u8, "POST");
    const url = try allocator.dupe(u8, "https://hooks.example.com/webhook");
    const entry = Entry{ .rule = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .http = .{ .method = method, .url = url } },
    } };
    free_entry_fields(entry, allocator);
    allocator.free(id);
}

test "free_entry_fields frees awf runner rule fields without inputs without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule.review");
    const pattern = try allocator.dupe(u8, "app.*");
    const workflow = try allocator.dupe(u8, "code-review");
    const inputs = try allocator.alloc([]const u8, 0);
    const entry = Entry{ .rule = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .awf = .{ .workflow = workflow, .inputs = inputs } },
    } };
    free_entry_fields(entry, allocator);
    allocator.free(id);
}

test "free_entry_fields frees awf runner rule fields with inputs without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule.report");
    const pattern = try allocator.dupe(u8, "report.*");
    const workflow = try allocator.dupe(u8, "generate-report");
    const input0 = try allocator.dupe(u8, "format=pdf");
    const input1 = try allocator.dupe(u8, "target=main");
    const inputs = try allocator.alloc([]const u8, 2);
    inputs[0] = input0;
    inputs[1] = input1;
    const entry = Entry{ .rule = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .awf = .{ .workflow = workflow, .inputs = inputs } },
    } };
    free_entry_fields(entry, allocator);
    allocator.free(id);
}

test "decode error on truncated awf runner" {
    // Truncated mid-workflow field
    const data = [_]u8{ 1, 0, 1, 97, 0, 1, 98, 3, 0, 5, 104 };
    try std.testing.expectError(DecodeError.InvalidData, decode(std.testing.allocator, &data));
}

test "encode decode direct runner round trip" {
    const args = [_][]const u8{ "--flag", "value" };
    const rule = domain.rule.Rule{
        .identifier = "rule1",
        .pattern = "*.log",
        .runner = .{ .direct = .{ .executable = "/usr/bin/cmd", .args = &args } },
    };
    const encoded = try encode(std.testing.allocator, .{ .rule = rule });
    defer std.testing.allocator.free(encoded);
    const decoded = try decode(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded.rule.identifier);
    defer std.testing.allocator.free(decoded.rule.pattern);
    defer std.testing.allocator.free(decoded.rule.runner.direct.executable);
    defer {
        for (decoded.rule.runner.direct.args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(decoded.rule.runner.direct.args);
    }
    try std.testing.expectEqualStrings("rule1", decoded.rule.identifier);
    try std.testing.expectEqualStrings("*.log", decoded.rule.pattern);
    try std.testing.expectEqualStrings("/usr/bin/cmd", decoded.rule.runner.direct.executable);
    try std.testing.expectEqual(@as(usize, 2), decoded.rule.runner.direct.args.len);
    try std.testing.expectEqualStrings("--flag", decoded.rule.runner.direct.args[0]);
    try std.testing.expectEqualStrings("value", decoded.rule.runner.direct.args[1]);
}
