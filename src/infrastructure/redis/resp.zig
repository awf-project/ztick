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

pub fn decode_value(allocator: std.mem.Allocator, reader: *std.Io.Reader) !RespValue {
    const first_byte = try reader.takeByte();
    switch (first_byte) {
        '+' => {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            _ = try reader.streamDelimiter(&aw.writer, '\n');
            _ = try reader.takeByte(); // consume '\n'
            const s = std.mem.trimEnd(u8, aw.writer.buffered(), "\r");
            return .{ .simple_string = try allocator.dupe(u8, s) };
        },
        '-' => {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            _ = try reader.streamDelimiter(&aw.writer, '\n');
            _ = try reader.takeByte(); // consume '\n'
            const s = std.mem.trimEnd(u8, aw.writer.buffered(), "\r");
            return .{ .error_msg = try allocator.dupe(u8, s) };
        },
        ':' => {
            var buf: [34]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            _ = try reader.streamDelimiter(&w, '\n');
            _ = try reader.takeByte(); // consume '\n'
            const s = std.mem.trimEnd(u8, w.buffered(), "\r");
            const n = std.fmt.parseInt(i64, s, 10) catch return error.InvalidInteger;
            return .{ .integer = n };
        },
        '$' => {
            var buf: [34]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            _ = try reader.streamDelimiter(&w, '\n');
            _ = try reader.takeByte(); // consume '\n'
            const s = std.mem.trimEnd(u8, w.buffered(), "\r");
            const len = std.fmt.parseInt(i64, s, 10) catch return error.InvalidBulkLength;
            if (len < 0) {
                return .{ .bulk_string = null };
            }
            const ulen: usize = @intCast(len);
            var data_list: std.ArrayListUnmanaged(u8) = .empty;
            errdefer data_list.deinit(allocator);
            try reader.appendExact(allocator, &data_list, ulen);
            const data = try data_list.toOwnedSlice(allocator);
            errdefer allocator.free(data);
            try reader.discardAll(2); // consume the trailing \r\n
            return .{ .bulk_string = data };
        },
        '*' => {
            var buf: [34]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            _ = try reader.streamDelimiter(&w, '\n');
            _ = try reader.takeByte(); // consume '\n'
            const s = std.mem.trimEnd(u8, w.buffered(), "\r");
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
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const items = [_][]const u8{ "SET", "foo", "bar" };
    try encode_array(&aw.writer, &items);
    try std.testing.expectEqualSlices(u8, "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n", aw.writer.buffered());
}

test "encode_array of PUBLISH channel payload produces RESP2 array bytes" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const items = [_][]const u8{ "PUBLISH", "channel", "payload" };
    try encode_array(&aw.writer, &items);
    try std.testing.expectEqualSlices(u8, "*3\r\n$7\r\nPUBLISH\r\n$7\r\nchannel\r\n$7\r\npayload\r\n", aw.writer.buffered());
}

test "encode_array of AUTH password produces single-arg AUTH bytes" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const items = [_][]const u8{ "AUTH", "password" };
    try encode_array(&aw.writer, &items);
    try std.testing.expectEqualSlices(u8, "*2\r\n$4\r\nAUTH\r\n$8\r\npassword\r\n", aw.writer.buffered());
}

test "encode_array of AUTH user password produces two-arg AUTH bytes" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const items = [_][]const u8{ "AUTH", "user", "password" };
    try encode_array(&aw.writer, &items);
    try std.testing.expectEqualSlices(u8, "*3\r\n$4\r\nAUTH\r\n$4\r\nuser\r\n$8\r\npassword\r\n", aw.writer.buffered());
}

test "encode_array of SELECT 3 produces SELECT bytes" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const items = [_][]const u8{ "SELECT", "3" };
    try encode_array(&aw.writer, &items);
    try std.testing.expectEqualSlices(u8, "*2\r\n$6\r\nSELECT\r\n$1\r\n3\r\n", aw.writer.buffered());
}

test "encode_bulk_string handles empty string" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encode_bulk_string(&aw.writer, "");
    try std.testing.expectEqualSlices(u8, "$0\r\n\r\n", aw.writer.buffered());
}

test "decode_value parses integer 42 reply" {
    var reader: std.Io.Reader = .fixed(":42\r\n");
    const val = try decode_value(std.testing.allocator, &reader);
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqual(@as(i64, 42), val.integer);
}

test "decode_value parses simple string OK reply" {
    var reader: std.Io.Reader = .fixed("+OK\r\n");
    const val = try decode_value(std.testing.allocator, &reader);
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqualStrings("OK", val.simple_string);
}

test "decode_value parses error message reply" {
    var reader: std.Io.Reader = .fixed("-ERR something\r\n");
    const val = try decode_value(std.testing.allocator, &reader);
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqualStrings("ERR something", val.error_msg);
}

test "decode_value parses bulk string hello reply" {
    var reader: std.Io.Reader = .fixed("$5\r\nhello\r\n");
    const val = try decode_value(std.testing.allocator, &reader);
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqualStrings("hello", val.bulk_string.?);
}

test "decode_value parses null bulk string reply" {
    var reader: std.Io.Reader = .fixed("$-1\r\n");
    const val = try decode_value(std.testing.allocator, &reader);
    defer free_value(std.testing.allocator, &val);
    try std.testing.expect(val.bulk_string == null);
}

test "decode_value parses array of bulk string and integer" {
    var reader: std.Io.Reader = .fixed("*2\r\n$3\r\nfoo\r\n:5\r\n");
    const val = try decode_value(std.testing.allocator, &reader);
    defer free_value(std.testing.allocator, &val);
    try std.testing.expectEqual(@as(usize, 2), val.array.len);
    try std.testing.expectEqualStrings("foo", val.array[0].bulk_string.?);
    try std.testing.expectEqual(@as(i64, 5), val.array[1].integer);
}

test "decode_value returns error on truncated bulk string length prefix" {
    var reader: std.Io.Reader = .fixed("$");
    const result = decode_value(std.testing.allocator, &reader);
    try std.testing.expectError(error.EndOfStream, result);
}
