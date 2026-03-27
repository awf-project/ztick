const std = @import("std");

pub const ParseError = error{ Incomplete, Invalid };

pub const ParseResult = struct {
    command: []u8,
    args: [][]u8,
    remaining: []const u8,

    pub fn deinit(self: ParseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.command);
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) (ParseError || std.mem.Allocator.Error)!ParseResult {
    var pos: usize = 0;

    while (pos < input.len and input[pos] == ' ') pos += 1;

    if (pos == input.len) return ParseError.Incomplete;
    if (input[pos] == '\n') return ParseError.Invalid;

    const command = try parse_token(allocator, input, &pos);
    errdefer allocator.free(command);

    while (pos < input.len and input[pos] == ' ') pos += 1;

    if (pos == input.len) return ParseError.Incomplete;
    if (input[pos] == '\n') {
        allocator.free(command);
        return ParseError.Invalid;
    }

    var args_list = std.ArrayListUnmanaged([]u8){};
    errdefer {
        for (args_list.items) |a| allocator.free(a);
        args_list.deinit(allocator);
    }

    while (pos < input.len and input[pos] != '\n') {
        const arg = try parse_token(allocator, input, &pos);
        args_list.append(allocator, arg) catch |err| {
            allocator.free(arg);
            return err;
        };
        while (pos < input.len and input[pos] == ' ') pos += 1;
    }

    if (pos == input.len) return ParseError.Incomplete;

    pos += 1; // skip '\n'

    const args = try args_list.toOwnedSlice(allocator);
    return ParseResult{
        .command = command,
        .args = args,
        .remaining = input[pos..],
    };
}

fn parse_token(allocator: std.mem.Allocator, input: []const u8, pos: *usize) (ParseError || std.mem.Allocator.Error)![]u8 {
    if (pos.* >= input.len) return ParseError.Incomplete;
    if (input[pos.*] == '"') return parse_quoted_string(allocator, input, pos);
    return parse_simple_string(allocator, input, pos);
}

fn parse_simple_string(allocator: std.mem.Allocator, input: []const u8, pos: *usize) std.mem.Allocator.Error![]u8 {
    const start = pos.*;
    while (pos.* < input.len and input[pos.*] != ' ' and input[pos.*] != '\n' and input[pos.*] != '"') {
        pos.* += 1;
    }
    return allocator.dupe(u8, input[start..pos.*]);
}

fn parse_quoted_string(allocator: std.mem.Allocator, input: []const u8, pos: *usize) (ParseError || std.mem.Allocator.Error)![]u8 {
    pos.* += 1; // skip opening '"'
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    while (pos.* < input.len) {
        const c = input[pos.*];
        if (c == '"') {
            pos.* += 1; // skip closing '"'
            return result.toOwnedSlice(allocator);
        } else if (c == '\\') {
            pos.* += 1;
            if (pos.* >= input.len) return ParseError.Incomplete;
            try result.append(allocator, input[pos.*]);
            pos.* += 1;
        } else {
            try result.append(allocator, c);
            pos.* += 1;
        }
    }

    return ParseError.Incomplete;
}

test "parse simple valid line" {
    const result = try parse(std.testing.allocator, "A VERSION\n");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A", result.command);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("VERSION", result.args[0]);
    try std.testing.expectEqualStrings("", result.remaining);
}

test "parse line with multiple args and surrounding spaces" {
    const result = try parse(std.testing.allocator, "    Id   VERSION toto   32t\\ata titi 111   \n");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Id", result.command);
    try std.testing.expectEqual(@as(usize, 5), result.args.len);
    try std.testing.expectEqualStrings("VERSION", result.args[0]);
    try std.testing.expectEqualStrings("toto", result.args[1]);
    try std.testing.expectEqualStrings("32t\\ata", result.args[2]);
    try std.testing.expectEqualStrings("titi", result.args[3]);
    try std.testing.expectEqualStrings("111", result.args[4]);
    try std.testing.expectEqualStrings("", result.remaining);
}

test "parse quoted strings" {
    const result = try parse(std.testing.allocator, "\"123\" \"UNSET\"\n");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("123", result.command);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("UNSET", result.args[0]);
    try std.testing.expectEqualStrings("", result.remaining);
}

test "parse backslash-escaped double quotes" {
    const result = try parse(std.testing.allocator, " \"\\\"\" \"\\\"\"   \n");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"", result.command);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("\"", result.args[0]);
    try std.testing.expectEqualStrings("", result.remaining);
}

test "parse mixed simple and quoted args with escape sequences" {
    const result = try parse(std.testing.allocator, "   *$a12  UNSET  \"\n\"  \"I can\\\" con$tain\\\\every.thing\\\"\"  \n");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("*$a12", result.command);
    try std.testing.expectEqual(@as(usize, 3), result.args.len);
    try std.testing.expectEqualStrings("UNSET", result.args[0]);
    try std.testing.expectEqualStrings("\n", result.args[1]);
    try std.testing.expectEqualStrings("I can\" con$tain\\every.thing\"", result.args[2]);
    try std.testing.expectEqualStrings("", result.remaining);
}

test "parse real-world SET command with quoted timestamp" {
    const result = try parse(std.testing.allocator, "A SET app.domain.example_job.0 \"2020-05-26 22:26:18\"\n");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A", result.command);
    try std.testing.expectEqual(@as(usize, 3), result.args.len);
    try std.testing.expectEqualStrings("SET", result.args[0]);
    try std.testing.expectEqualStrings("app.domain.example_job.0", result.args[1]);
    try std.testing.expectEqualStrings("2020-05-26 22:26:18", result.args[2]);
    try std.testing.expectEqualStrings("", result.remaining);
}

test "parse valid line followed by more data returns remainder" {
    const result = try parse(std.testing.allocator, "A VERSION\ntoto\nhey");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("A", result.command);
    try std.testing.expectEqual(@as(usize, 1), result.args.len);
    try std.testing.expectEqualStrings("VERSION", result.args[0]);
    try std.testing.expectEqualStrings("toto\nhey", result.remaining);
}

test "parse complex line with remainder" {
    const result = try parse(std.testing.allocator, "  XYZ    UNSET  \"\n\"  \"I can\\\" con$tain\\\\every.thing\\\"\"  \n\n\nHEYHEY \"next");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("XYZ", result.command);
    try std.testing.expectEqual(@as(usize, 3), result.args.len);
    try std.testing.expectEqualStrings("UNSET", result.args[0]);
    try std.testing.expectEqualStrings("\n", result.args[1]);
    try std.testing.expectEqualStrings("I can\" con$tain\\every.thing\"", result.args[2]);
    try std.testing.expectEqualStrings("\n\nHEYHEY \"next", result.remaining);
}

test "parse invalid: bare newline" {
    try std.testing.expectError(ParseError.Invalid, parse(std.testing.allocator, "\n"));
}

test "parse incomplete: no newline" {
    try std.testing.expectError(ParseError.Incomplete, parse(std.testing.allocator, "VER"));
}

test "parse incomplete: partial quoted string" {
    try std.testing.expectError(ParseError.Incomplete, parse(std.testing.allocator, " \"\\"));
}
