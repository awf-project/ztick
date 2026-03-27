const std = @import("std");

pub const max_entry_size: usize = std.math.maxInt(u32);

pub const EncodeError = error{MaximumSizeReached};
pub const ParseError = error{ CorruptedContent, Incomplete };

pub fn encode(allocator: std.mem.Allocator, entry: []const u8) EncodeError![]u8 {
    if (entry.len > max_entry_size) return EncodeError.MaximumSizeReached;
    const result = allocator.alloc(u8, 4 + entry.len) catch return EncodeError.MaximumSizeReached;
    std.mem.writeInt(u32, result[0..4], @intCast(entry.len), .big);
    @memcpy(result[4..], entry);
    return result;
}

pub const ParseResult = struct {
    entries: [][]u8,
    remaining: []const u8,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) (ParseError || std.mem.Allocator.Error)!ParseResult {
    var entries = std.ArrayListUnmanaged([]u8){};
    errdefer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < input.len) {
        if (pos + 4 > input.len) {
            const owned = try entries.toOwnedSlice(allocator);
            return ParseResult{ .entries = owned, .remaining = input[pos..] };
        }
        const size = std.mem.readInt(u32, input[pos..][0..4], .big);
        if (pos + 4 + size > input.len) {
            const owned = try entries.toOwnedSlice(allocator);
            return ParseResult{ .entries = owned, .remaining = input[pos..] };
        }
        const entry = try allocator.dupe(u8, input[pos + 4 .. pos + 4 + size]);
        try entries.append(allocator, entry);
        pos += 4 + size;
    }

    return ParseResult{ .entries = try entries.toOwnedSlice(allocator), .remaining = input[pos..] };
}

test "encode empty entry" {
    const result = try encode(std.testing.allocator, &[_]u8{});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, result);
}

test "encode single byte entry" {
    const result = try encode(std.testing.allocator, &[_]u8{0});
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 0 }, result);
}

test "encode multi-byte entry" {
    const result = try encode(std.testing.allocator, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 });
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 8, 0, 1, 2, 3, 4, 5, 6, 7 }, result);
}

test "parse single entry" {
    const result = try parse(std.testing.allocator, &[_]u8{ 0, 0, 0, 1, 0 });
    defer {
        for (result.entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(result.entries);
    }
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, result.entries[0]);
    try std.testing.expectEqual(@as(usize, 0), result.remaining.len);
}

test "parse two entries" {
    const result = try parse(std.testing.allocator, &[_]u8{ 0, 0, 0, 1, 0, 0, 0, 0, 1, 1 });
    defer {
        for (result.entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(result.entries);
    }
    try std.testing.expectEqual(@as(usize, 2), result.entries.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, result.entries[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{1}, result.entries[1]);
}

test "parse incomplete header" {
    const result = try parse(std.testing.allocator, &[_]u8{0});
    defer {
        for (result.entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(result.entries);
    }
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, result.remaining);
}

test "parse incomplete body" {
    const result = try parse(std.testing.allocator, &[_]u8{ 0, 0, 0, 1 });
    defer {
        for (result.entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(result.entries);
    }
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1 }, result.remaining);
}

test "parse partial second entry" {
    const result = try parse(std.testing.allocator, &[_]u8{ 0, 0, 0, 1, 0, 0, 0, 0, 2 });
    defer {
        for (result.entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(result.entries);
    }
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, result.entries[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 2 }, result.remaining);
}

test "parse multi-byte body" {
    const result = try parse(std.testing.allocator, &[_]u8{ 0, 0, 0, 8, 0, 1, 2, 3, 4, 5, 6, 7 });
    defer {
        for (result.entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(result.entries);
    }
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 }, result.entries[0]);
    try std.testing.expectEqual(@as(usize, 0), result.remaining.len);
}

test "parse incomplete body partial data" {
    const result = try parse(std.testing.allocator, &[_]u8{ 0, 0, 0, 8, 0, 1, 2, 3 });
    defer {
        for (result.entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(result.entries);
    }
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 8, 0, 1, 2, 3 }, result.remaining);
}
