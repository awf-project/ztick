const std = @import("std");
const cli = @import("cli.zig");
const domain = @import("../domain.zig");
const infrastructure = @import("../infrastructure.zig");

const Entry = infrastructure.persistence.encoder.Entry;
const JobStatus = domain.job.JobStatus;

pub const DumpError = error{
    FileNotFound,
    PermissionDenied,
};

fn status_to_str(status: JobStatus) []const u8 {
    return switch (status) {
        .planned => "planned",
        .triggered => "triggered",
        .executed => "executed",
        .failed => "failed",
    };
}

pub fn format_entry_text(writer: anytype, entry: Entry) !void {
    switch (entry) {
        .job => |job| {
            try writer.print("SET {s} {d} {s}\n", .{ job.identifier, job.execution, status_to_str(job.status) });
        },
        .rule => |rule| {
            switch (rule.runner) {
                .shell => |sh| try writer.print("RULE SET {s} {s} shell {s}\n", .{ rule.identifier, rule.pattern, sh.command }),
                .amqp => |amqp| try writer.print("RULE SET {s} {s} amqp {s} {s} {s}\n", .{ rule.identifier, rule.pattern, amqp.dsn, amqp.exchange, amqp.routing_key }),
                .direct => |d| {
                    try writer.print("RULE SET {s} {s} direct {s}", .{ rule.identifier, rule.pattern, d.executable });
                    for (d.args) |arg| try writer.print(" {s}", .{arg});
                    try writer.writeByte('\n');
                },
            }
        },
        .job_removal => |r| try writer.print("REMOVE {s}\n", .{r.identifier}),
        .rule_removal => |r| try writer.print("REMOVERULE {s}\n", .{r.identifier}),
    }
}

fn write_json_string(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

pub fn format_entry_json(writer: anytype, entry: Entry) !void {
    switch (entry) {
        .job => |job| {
            try writer.writeAll("{\"type\":\"set\",\"identifier\":");
            try write_json_string(writer, job.identifier);
            try writer.print(",\"execution\":{d},\"status\":", .{job.execution});
            try write_json_string(writer, status_to_str(job.status));
            try writer.writeByte('}');
        },
        .rule => |rule| {
            try writer.writeAll("{\"type\":\"rule_set\",\"identifier\":");
            try write_json_string(writer, rule.identifier);
            try writer.writeAll(",\"pattern\":");
            try write_json_string(writer, rule.pattern);
            try writer.writeAll(",\"runner\":");
            switch (rule.runner) {
                .shell => |sh| {
                    try writer.writeAll("{\"type\":\"shell\",\"command\":");
                    try write_json_string(writer, sh.command);
                    try writer.writeAll("}}");
                },
                .amqp => |amqp| {
                    try writer.writeAll("{\"type\":\"amqp\",\"dsn\":");
                    try write_json_string(writer, amqp.dsn);
                    try writer.writeAll(",\"exchange\":");
                    try write_json_string(writer, amqp.exchange);
                    try writer.writeAll(",\"routing_key\":");
                    try write_json_string(writer, amqp.routing_key);
                    try writer.writeAll("}}");
                },
                .direct => |d| {
                    try writer.writeAll("{\"type\":\"direct\",\"executable\":");
                    try write_json_string(writer, d.executable);
                    try writer.writeAll(",\"args\":[");
                    for (d.args, 0..) |arg, i| {
                        if (i > 0) try writer.writeByte(',');
                        try write_json_string(writer, arg);
                    }
                    try writer.writeAll("]}}");
                },
            }
        },
        .job_removal => |r| {
            try writer.writeAll("{\"type\":\"remove\",\"identifier\":");
            try write_json_string(writer, r.identifier);
            try writer.writeByte('}');
        },
        .rule_removal => |r| {
            try writer.writeAll("{\"type\":\"remove_rule\",\"identifier\":");
            try write_json_string(writer, r.identifier);
            try writer.writeByte('}');
        },
    }
}

fn write_entry(writer: anytype, entry: Entry, format: cli.Format) !void {
    switch (format) {
        .text => try format_entry_text(writer, entry),
        .json => {
            try format_entry_json(writer, entry);
            try writer.writeByte('\n');
        },
    }
}

fn entry_identifier(entry: Entry) []const u8 {
    return switch (entry) {
        .job => |j| j.identifier,
        .rule => |r| r.identifier,
        .job_removal => |r| r.identifier,
        .rule_removal => |r| r.identifier,
    };
}

var follow_running_ptr: ?*std.atomic.Value(bool) = null;

fn follow_signal_handler(sig: c_int) callconv(.c) void {
    _ = sig;
    if (follow_running_ptr) |ptr| {
        ptr.store(false, .release);
    }
}

fn follow_loop(allocator: std.mem.Allocator, options: cli.DumpOptions, initial_offset: u64, writer: anytype, running: *std.atomic.Value(bool)) !void {
    running.store(true, .release);

    const act = std.posix.Sigaction{
        .handler = .{ .handler = follow_signal_handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    const file = try std.fs.cwd().openFile(options.logfile_path, .{});
    defer file.close();

    var offset = initial_offset;

    while (running.load(.acquire)) {
        const stat = try file.stat();

        if (stat.size > offset) {
            try file.seekTo(offset);
            const new_data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(new_data);

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const parse_result = try infrastructure.persistence.logfile.parse(arena.allocator(), new_data);

            for (parse_result.entries, 0..) |frame, i| {
                const entry = infrastructure.persistence.encoder.decode(arena.allocator(), frame) catch |err| {
                    const stderr = std.fs.File.stderr().deprecatedWriter();
                    stderr.print("warning: failed to decode frame {d}: {}\n", .{ i, err }) catch {};
                    continue;
                };
                try write_entry(writer, entry, options.format);
            }

            offset += new_data.len - parse_result.remaining.len;
        }

        std.Thread.sleep(500_000_000);
    }
}

fn write_compact_entries(writer: anytype, frames: []const []u8, format: cli.Format, arena_allocator: std.mem.Allocator) !void {
    var entries = std.ArrayListUnmanaged(Entry){};
    for (frames, 0..) |frame, i| {
        const entry = infrastructure.persistence.encoder.decode(arena_allocator, frame) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("warning: failed to decode frame {d}: {}\n", .{ i, err }) catch {};
            continue;
        };
        try entries.append(arena_allocator, entry);
    }

    var last_index = std.StringHashMapUnmanaged(usize){};
    for (entries.items, 0..) |entry, j| {
        try last_index.put(arena_allocator, entry_identifier(entry), j);
    }

    for (entries.items, 0..) |entry, j| {
        const id = entry_identifier(entry);
        if (last_index.get(id) != j) continue;
        switch (entry) {
            .job_removal, .rule_removal => continue,
            else => {},
        }
        try write_entry(writer, entry, format);
    }
}

pub fn run_dump(allocator: std.mem.Allocator, options: cli.DumpOptions) !void {
    const file = std.fs.cwd().openFile(options.logfile_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return DumpError.FileNotFound,
        error.AccessDenied => return DumpError.PermissionDenied,
        else => return err,
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parse_result = try infrastructure.persistence.logfile.parse(arena.allocator(), data);

    if (parse_result.remaining.len > 0) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("warning: partial trailing frame ({d} bytes) ignored\n", .{parse_result.remaining.len}) catch {};
    }

    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (options.compact) {
        try write_compact_entries(stdout, parse_result.entries, options.format, arena.allocator());
    } else {
        for (parse_result.entries, 0..) |frame, i| {
            const entry = infrastructure.persistence.encoder.decode(arena.allocator(), frame) catch |err| {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("warning: failed to decode frame {d}: {}\n", .{ i, err }) catch {};
                continue;
            };
            try write_entry(stdout, entry, options.format);
        }
    }

    if (options.follow) {
        var follow_running = std.atomic.Value(bool).init(true);
        follow_running_ptr = &follow_running;
        try follow_loop(allocator, options, data.len - parse_result.remaining.len, stdout, &follow_running);
    }
}

test "format_entry_text writes SET line for job entry" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const job_entry = Entry{ .job = .{ .identifier = "my-job", .execution = 1605457800_000000000, .status = .planned } };
    try format_entry_text(fbs.writer(), job_entry);
    try std.testing.expectEqualStrings("SET my-job 1605457800000000000 planned\n", fbs.getWritten());
}

test "format_entry_text writes RULE SET line for shell runner rule entry" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const rule_entry = Entry{ .rule = .{
        .identifier = "my-rule",
        .pattern = "*/5 * * * *",
        .runner = .{ .shell = .{ .command = "echo hello" } },
    } };
    try format_entry_text(fbs.writer(), rule_entry);
    try std.testing.expectEqualStrings("RULE SET my-rule */5 * * * * shell echo hello\n", fbs.getWritten());
}

test "format_entry_text writes REMOVE line for job removal entry" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const removal_entry = Entry{ .job_removal = .{ .identifier = "old-job" } };
    try format_entry_text(fbs.writer(), removal_entry);
    try std.testing.expectEqualStrings("REMOVE old-job\n", fbs.getWritten());
}

test "format_entry_text writes REMOVERULE line for rule removal entry" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const removal_entry = Entry{ .rule_removal = .{ .identifier = "old-rule" } };
    try format_entry_text(fbs.writer(), removal_entry);
    try std.testing.expectEqualStrings("REMOVERULE old-rule\n", fbs.getWritten());
}

test "format_entry_json writes set object for job entry" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const job_entry = Entry{ .job = .{ .identifier = "my-job", .execution = 1605457800_000000000, .status = .planned } };
    try format_entry_json(fbs.writer(), job_entry);
    try std.testing.expectEqualStrings(
        "{\"type\":\"set\",\"identifier\":\"my-job\",\"execution\":1605457800000000000,\"status\":\"planned\"}",
        fbs.getWritten(),
    );
}

test "format_entry_json writes rule_set object with shell runner" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const rule_entry = Entry{ .rule = .{
        .identifier = "my-rule",
        .pattern = "*/5 * * * *",
        .runner = .{ .shell = .{ .command = "echo hello" } },
    } };
    try format_entry_json(fbs.writer(), rule_entry);
    try std.testing.expectEqualStrings(
        "{\"type\":\"rule_set\",\"identifier\":\"my-rule\",\"pattern\":\"*/5 * * * *\",\"runner\":{\"type\":\"shell\",\"command\":\"echo hello\"}}",
        fbs.getWritten(),
    );
}

test "format_entry_json writes rule_set object with amqp runner" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const rule_entry = Entry{ .rule = .{
        .identifier = "amqp-rule",
        .pattern = "notify.",
        .runner = .{ .amqp = .{ .dsn = "amqp://localhost", .exchange = "events", .routing_key = "job.done" } },
    } };
    try format_entry_json(fbs.writer(), rule_entry);
    try std.testing.expectEqualStrings(
        "{\"type\":\"rule_set\",\"identifier\":\"amqp-rule\",\"pattern\":\"notify.\",\"runner\":{\"type\":\"amqp\",\"dsn\":\"amqp://localhost\",\"exchange\":\"events\",\"routing_key\":\"job.done\"}}",
        fbs.getWritten(),
    );
}

test "format_entry_json writes remove object for job removal" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const removal_entry = Entry{ .job_removal = .{ .identifier = "old-job" } };
    try format_entry_json(fbs.writer(), removal_entry);
    try std.testing.expectEqualStrings(
        "{\"type\":\"remove\",\"identifier\":\"old-job\"}",
        fbs.getWritten(),
    );
}

test "format_entry_json writes remove_rule object for rule removal" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const removal_entry = Entry{ .rule_removal = .{ .identifier = "old-rule" } };
    try format_entry_json(fbs.writer(), removal_entry);
    try std.testing.expectEqualStrings(
        "{\"type\":\"remove_rule\",\"identifier\":\"old-rule\"}",
        fbs.getWritten(),
    );
}

test "write_entry with text format writes text line without trailing newline in output" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const entry = Entry{ .job = .{ .identifier = "j1", .execution = 1000000000, .status = .planned } };
    try write_entry(fbs.writer(), entry, .text);
    try std.testing.expectEqualStrings("SET j1 1000000000 planned\n", fbs.getWritten());
}

test "write_entry with json format writes JSON object with trailing newline" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const entry = Entry{ .job = .{ .identifier = "j1", .execution = 1000000000, .status = .planned } };
    try write_entry(fbs.writer(), entry, .json);
    try std.testing.expectEqualStrings(
        "{\"type\":\"set\",\"identifier\":\"j1\",\"execution\":1000000000,\"status\":\"planned\"}\n",
        fbs.getWritten(),
    );
}

test "write_entry with json format writes rule entry as NDJSON line" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const entry = Entry{ .rule = .{
        .identifier = "r1",
        .pattern = "* * * * *",
        .runner = .{ .shell = .{ .command = "notify" } },
    } };
    try write_entry(fbs.writer(), entry, .json);
    try std.testing.expectEqualStrings(
        "{\"type\":\"rule_set\",\"identifier\":\"r1\",\"pattern\":\"* * * * *\",\"runner\":{\"type\":\"shell\",\"command\":\"notify\"}}\n",
        fbs.getWritten(),
    );
}

test "format_entry_text writes RULE SET line for direct runner with no args" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const rule_entry = Entry{ .rule = .{
        .identifier = "direct-rule",
        .pattern = "* * * * *",
        .runner = .{ .direct = .{ .executable = "/usr/bin/notify-send", .args = &.{} } },
    } };
    try format_entry_text(fbs.writer(), rule_entry);
    try std.testing.expectEqualStrings("RULE SET direct-rule * * * * * direct /usr/bin/notify-send\n", fbs.getWritten());
}

test "format_entry_text writes RULE SET line for direct runner with args" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const args = [_][]const u8{ "-s", "http://example.com" };
    const rule_entry = Entry{ .rule = .{
        .identifier = "curl-rule",
        .pattern = "0 * * * *",
        .runner = .{ .direct = .{ .executable = "/usr/bin/curl", .args = &args } },
    } };
    try format_entry_text(fbs.writer(), rule_entry);
    try std.testing.expectEqualStrings("RULE SET curl-rule 0 * * * * direct /usr/bin/curl -s http://example.com\n", fbs.getWritten());
}

test "format_entry_json writes rule_set object with direct runner and no args" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const rule_entry = Entry{ .rule = .{
        .identifier = "direct-rule",
        .pattern = "* * * * *",
        .runner = .{ .direct = .{ .executable = "/usr/bin/notify-send", .args = &.{} } },
    } };
    try format_entry_json(fbs.writer(), rule_entry);
    try std.testing.expectEqualStrings(
        "{\"type\":\"rule_set\",\"identifier\":\"direct-rule\",\"pattern\":\"* * * * *\",\"runner\":{\"type\":\"direct\",\"executable\":\"/usr/bin/notify-send\",\"args\":[]}}",
        fbs.getWritten(),
    );
}

test "format_entry_json writes rule_set object with direct runner and args" {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const args = [_][]const u8{ "-s", "http://example.com" };
    const rule_entry = Entry{ .rule = .{
        .identifier = "curl-rule",
        .pattern = "0 * * * *",
        .runner = .{ .direct = .{ .executable = "/usr/bin/curl", .args = &args } },
    } };
    try format_entry_json(fbs.writer(), rule_entry);
    try std.testing.expectEqualStrings(
        "{\"type\":\"rule_set\",\"identifier\":\"curl-rule\",\"pattern\":\"0 * * * *\",\"runner\":{\"type\":\"direct\",\"executable\":\"/usr/bin/curl\",\"args\":[\"-s\",\"http://example.com\"]}}",
        fbs.getWritten(),
    );
}
