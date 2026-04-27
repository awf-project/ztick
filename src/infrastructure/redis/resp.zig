const std = @import("std");

pub const RespValue = union(enum) {
    integer: i64,
    simple_string: []const u8,
    bulk_string: ?[]const u8,
    error_msg: []const u8,
    array: []RespValue,
};

pub fn encode_array(writer: anytype, items: []const []const u8) !void {
    try writer.print("*{d}\r\n", .{items.len});
    for (items) |item| {
        try encode_bulk_string(writer, item);
    }
}

pub fn encode_bulk_string(writer: anytype, s: []const u8) !void {
    try writer.print("${d}\r\n{s}\r\n", .{ s.len, s });
}

pub fn decode_value(allocator: std.mem.Allocator, reader: anytype) !RespValue {
    const first_byte = try reader.readByte();
    switch (first_byte) {
        '+' => {
            const line = try reader.readUntilDelimiterAlloc(allocator, '\n', 4096);
            defer allocator.free(line);
            const s = std.mem.trimRight(u8, line, "\r");
            return .{ .simple_string = try allocator.dupe(u8, s) };
        },
        '-' => {
            const line = try reader.readUntilDelimiterAlloc(allocator, '\n', 4096);
            defer allocator.free(line);
            const s = std.mem.trimRight(u8, line, "\r");
            return .{ .error_msg = try allocator.dupe(u8, s) };
        },
        ':' => {
            var buf: [32]u8 = undefined;
            const line = try reader.readUntilDelimiter(&buf, '\n');
            const s = std.mem.trimRight(u8, line, "\r");
            const n = std.fmt.parseInt(i64, s, 10) catch return error.InvalidInteger;
            return .{ .integer = n };
        },
        '$' => {
            var buf: [32]u8 = undefined;
            const line = try reader.readUntilDelimiter(&buf, '\n');
            const s = std.mem.trimRight(u8, line, "\r");
            const len = std.fmt.parseInt(i64, s, 10) catch return error.InvalidBulkLength;
            if (len < 0) {
                return .{ .bulk_string = null };
            }
            const ulen: usize = @intCast(len);
            const data = try allocator.alloc(u8, ulen);
            errdefer allocator.free(data);
            try reader.readNoEof(data);
            try reader.skipBytes(2, .{});
            return .{ .bulk_string = data };
        },
        '*' => {
            var buf: [32]u8 = undefined;
            const line = try reader.readUntilDelimiter(&buf, '\n');
            const s = std.mem.trimRight(u8, line, "\r");
            const count = std.fmt.parseInt(usize, s, 10) catch return error.InvalidArrayLen;
            const items = try allocator.alloc(RespValue, count);
            for (items, 0..) |*item, i| {
                item.* = decode_value(allocator, reader) catch |err| {
                    for (items[0..i]) |*prev| free_value(allocator, prev);
                    allocator.free(items);
                    return err;
                };
            }
            return .{ .array = items };
        },
        else => return error.UnknownType,
    }
}

pub fn free_value(allocator: std.mem.Allocator, value: *const RespValue) void {
    switch (value.*) {
        .integer => {},
        .simple_string => |s| allocator.free(s),
        .error_msg => |s| allocator.free(s),
        .bulk_string => |s| if (s) |data| allocator.free(data),
        .array => |items| {
            for (items) |*item| free_value(allocator, item);
            allocator.free(items);
        },
    }
}

test "encode_array of SET foo bar produces RESP2 array bytes" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    const items = [_][]const u8{ "SET", "foo", "bar" };
    try encode_array(buf.writer(std.testing.allocator), &items);
    try std.testing.expectEqualSlices(u8, "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n", buf.items);
}

test "encode_array of PUBLISH channel payload produces RESP2 array bytes" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    const items = [_][]const u8{ "PUBLISH", "channel", "payload" };
    try encode_array(buf.writer(std.testing.allocator), &items);
    try std.testing.expectEqualSlices(u8, "*3\r\n$7\r\nPUBLISH\r\n$7\r\nchannel\r\n$7\r\npayload\r\n", buf.items);
}

test "encode_array of AUTH password produces single-arg AUTH bytes" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    const items = [_][]const u8{ "AUTH", "password" };
    try encode_array(buf.writer(std.testing.allocator), &items);
    try std.testing.expectEqualSlices(u8, "*2\r\n$4\r\nAUTH\r\n$8\r\npassword\r\n", buf.items);
}

test "encode_array of AUTH user password produces two-arg AUTH bytes" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    const items = [_][]const u8{ "AUTH", "user", "password" };
    try encode_array(buf.writer(std.testing.allocator), &items);
    try std.testing.expectEqualSlices(u8, "*3\r\n$4\r\nAUTH\r\n$4\r\nuser\r\n$8\r\npassword\r\n", buf.items);
}

test "encode_array of SELECT 3 produces SELECT bytes" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    const items = [_][]const u8{ "SELECT", "3" };
    try encode_array(buf.writer(std.testing.allocator), &items);
    try std.testing.expectEqualSlices(u8, "*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n", buf.items);
}

test "encode_bulk_string handles empty string" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    try encode_bulk_string(buf.writer(std.testing.allocator), "");
    try std.testing.expectEqualSlices(u8, "$0\r\n\r\n", buf.items);
}

test "decode_value parses integer 42 reply" {
    var stream = std.io.fixedBufferStream(":42\r\n");
    const val = try decode_value(std.testing.allocator, stream.reader());
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqual(@as(i64, 42), val.integer);
}

test "decode_value parses simple string OK reply" {
    var stream = std.io.fixedBufferStream("+OK\r\n");
    const val = try decode_value(std.testing.allocator, stream.reader());
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqualStrings("OK", val.simple_string);
}

test "decode_value parses error message reply" {
    var stream = std.io.fixedBufferStream("-ERR something\r\n");
    const val = try decode_value(std.testing.allocator, stream.reader());
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqualStrings("ERR something", val.error_msg);
}

test "decode_value parses bulk string hello reply" {
    var stream = std.io.fixedBufferStream("$5\r\nhello\r\n");
    const val = try decode_value(std.testing.allocator, stream.reader());
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqualStrings("hello", val.bulk_string.?);
}

test "decode_value parses null bulk string reply" {
    var stream = std.io.fixedBufferStream("$-1\r\n");
    const val = try decode_value(std.testing.allocator, stream.reader());
    defer free_value(std.testing.allocator, &val);
    try std.testing.expect(val.bulk_string == null);
}

test "decode_value parses array of bulk string and integer" {
    var stream = std.io.fixedBufferStream("*2\r\n$3\r\nfoo\r\n:5\r\n");
    const val = try decode_value(std.testing.allocator, stream.reader());
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqual(@as(usize, 2), val.array.len);
    try std.testing.expectEqualStrings("foo", val.array[0].bulk_string.?);
    try std.testing.expectEqual(@as(i64, 5), val.array[1].integer);
}

test "decode_value returns error on truncated bulk string length prefix" {
    var stream = std.io.fixedBufferStream("$");
    const result = decode_value(std.testing.allocator, stream.reader());
    try std.testing.expectError(error.EndOfStream, result);
}
