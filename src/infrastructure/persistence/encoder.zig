const std = @import("std");
const domain = @import("../../domain.zig");

pub const DecodeError = error{InvalidData};

/// Persisted entry types. GET and QUERY instructions are read-only and skipped at the
/// scheduler layer (scheduler.zig:append_to_logfile), so no encoder variant is needed.
pub const Entry = union(enum) {
    job: domain.job.Job,
    rule: domain.rule.Rule,
};

pub fn encode(allocator: std.mem.Allocator, value: Entry) ![]u8 {
    return switch (value) {
        .job => |job| encode_job(allocator, job),
        .rule => |rule| encode_rule(allocator, rule),
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
    }
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
                else => return error.InvalidData,
            }
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

/// Free all heap-allocated fields of a decoded Entry, except the identifier.
/// After calling, only the entry's identifier slice remains valid; the caller is
/// responsible for freeing it.
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
            }
        },
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
