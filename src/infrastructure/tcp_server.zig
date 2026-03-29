const std = @import("std");
const domain = @import("../domain.zig");
const parser = @import("protocol/parser.zig");
const Channel = @import("channel.zig").Channel;

const query = domain.query;
const instruction = domain.instruction;

pub const ResponseRouter = struct {
    mutex: std.Thread.Mutex,
    channels: std.AutoHashMap(query.Client, *Channel(query.Response)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ResponseRouter {
        return .{
            .mutex = .{},
            .channels = std.AutoHashMap(query.Client, *Channel(query.Response)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResponseRouter) void {
        self.channels.deinit();
    }

    pub fn register(self: *ResponseRouter, client_id: query.Client, channel: *Channel(query.Response)) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.channels.put(client_id, channel) catch return;
    }

    pub fn deregister(self: *ResponseRouter, client_id: query.Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.channels.remove(client_id);
    }

    pub fn route(self: *ResponseRouter, response: query.Response) void {
        self.mutex.lock();
        const channel = self.channels.get(response.request.client);
        self.mutex.unlock();
        if (channel) |ch| {
            ch.send(response) catch {};
        }
    }
};

pub const TcpServer = struct {
    allocator: std.mem.Allocator,
    address: []const u8,
    threads: std.ArrayListUnmanaged(std.Thread),
    running: *std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, address: []const u8, running: *std.atomic.Value(bool)) TcpServer {
        return .{
            .allocator = allocator,
            .address = address,
            .threads = std.ArrayListUnmanaged(std.Thread){},
            .running = running,
        };
    }

    pub fn deinit(self: *TcpServer) void {
        self.threads.deinit(self.allocator);
    }

    pub fn start(
        self: *TcpServer,
        request_channel: *Channel(query.Request),
        response_router: *ResponseRouter,
    ) !void {
        const colon = std.mem.lastIndexOf(u8, self.address, ":") orelse return error.InvalidAddress;
        const host = self.address[0..colon];
        const port = try std.fmt.parseInt(u16, self.address[colon + 1 ..], 10);
        const addr = try std.net.Address.parseIp(host, port);
        var server = try addr.listen(.{});

        var next_client_id: u128 = 0;

        while (self.running.load(.acquire)) {
            const conn = server.accept() catch {
                // Accept failed, likely due to listener being closed from shutdown
                if (!self.running.load(.acquire)) break;
                continue;
            };

            const client_id = next_client_id;
            next_client_id +%= 1;

            const thread = std.Thread.spawn(.{}, handle_connection, .{
                self.allocator,
                conn.stream,
                client_id,
                request_channel,
                response_router,
            }) catch {
                conn.stream.close();
                continue;
            };
            self.threads.append(self.allocator, thread) catch continue;
        }

        server.deinit();
    }

    pub fn join_all(self: *TcpServer) void {
        for (self.threads.items) |thread| {
            thread.join();
        }
        self.threads.clearAndFree(self.allocator);
    }
};

fn handle_connection(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    client_id: u128,
    request_channel: *Channel(query.Request),
    response_router: *ResponseRouter,
) void {
    defer stream.close();

    // Create a per-connection response channel
    var response_channel = Channel(query.Response).init(allocator, 1) catch return;
    defer response_channel.deinit();

    response_router.register(client_id, &response_channel);
    defer response_router.deregister(client_id);

    var buf: [4096]u8 = undefined;
    var filled: usize = 0;

    while (true) {
        const n = stream.read(buf[filled..]) catch return;
        if (n == 0) return; // client disconnected

        filled += n;

        var consumed: usize = 0;
        while (true) {
            const data = buf[consumed..filled];
            const result = parser.parse(allocator, data) catch |err| switch (err) {
                error.Incomplete => break, // need more data
                error.Invalid => {
                    // Skip the invalid line (find next newline)
                    if (std.mem.indexOfScalar(u8, data, '\n')) |nl| {
                        consumed += nl + 1;
                        continue;
                    }
                    break;
                },
                error.OutOfMemory => return,
            };

            consumed = filled - result.remaining.len;

            if (build_instruction(allocator, result) catch {
                result.deinit(allocator);
                return;
            }) |instr| {
                // Instruction owns duped strings; free all parsed args uniformly.
                for (result.args) |arg| allocator.free(arg);
                allocator.free(result.args);

                const request = query.Request{
                    .client = client_id,
                    .identifier = result.command,
                    .instruction = instr,
                };

                request_channel.send(request) catch {
                    // Send failed — we still own the strings, free them
                    allocator.free(result.command);
                    free_instruction_strings(allocator, instr);
                    return;
                };

                // Wait for response and write back to client
                if (response_channel.receive()) |resp| {
                    write_response(allocator, stream, resp) catch {};
                    // Free only the request_id (result.command) — not stored by scheduler.
                    // Instruction strings (job id, pattern, runner args) are now owned
                    // by the scheduler's storage and must not be freed here.
                    allocator.free(resp.request.identifier);
                    if (resp.body) |body| allocator.free(body);
                } else {
                    return; // channel closed
                }
            } else {
                result.deinit(allocator);
            }
        }

        // Move unparsed data to the front of the buffer
        if (consumed > 0) {
            const remaining = filled - consumed;
            if (remaining > 0) {
                std.mem.copyBackwards(u8, buf[0..remaining], buf[consumed..filled]);
            }
            filled = remaining;
        }
    }
}

fn build_instruction(allocator: std.mem.Allocator, result: parser.ParseResult) error{OutOfMemory}!?instruction.Instruction {
    if (result.args.len >= 2 and std.mem.eql(u8, result.args[0], "GET")) {
        const id = try allocator.dupe(u8, result.args[1]);
        return .{ .get = .{ .identifier = id } };
    }

    if (result.args.len >= 3 and std.mem.eql(u8, result.args[0], "SET")) {
        const id = try allocator.dupe(u8, result.args[1]);
        return .{ .set = .{
            .identifier = id,
            .execution = parse_timestamp(result.args[2..]),
        } };
    }

    if (result.args.len >= 4 and
        std.mem.eql(u8, result.args[0], "RULE") and
        std.mem.eql(u8, result.args[1], "SET"))
    {
        const runner_type = result.args[4..];
        if (runner_type.len >= 2 and std.mem.eql(u8, runner_type[0], "shell")) {
            const id = try allocator.dupe(u8, result.args[2]);
            errdefer allocator.free(id);
            const pattern = try allocator.dupe(u8, result.args[3]);
            errdefer allocator.free(pattern);
            const command = try allocator.dupe(u8, runner_type[1]);
            return .{ .rule_set = .{
                .identifier = id,
                .pattern = pattern,
                .runner = .{ .shell = .{ .command = command } },
            } };
        }
        if (runner_type.len >= 4 and std.mem.eql(u8, runner_type[0], "amqp")) {
            const id = try allocator.dupe(u8, result.args[2]);
            errdefer allocator.free(id);
            const pattern = try allocator.dupe(u8, result.args[3]);
            errdefer allocator.free(pattern);
            const dsn = try allocator.dupe(u8, runner_type[1]);
            errdefer allocator.free(dsn);
            const exchange = try allocator.dupe(u8, runner_type[2]);
            errdefer allocator.free(exchange);
            const routing_key = try allocator.dupe(u8, runner_type[3]);
            return .{ .rule_set = .{
                .identifier = id,
                .pattern = pattern,
                .runner = .{ .amqp = .{
                    .dsn = dsn,
                    .exchange = exchange,
                    .routing_key = routing_key,
                } },
            } };
        }
    }

    return null;
}

fn parse_timestamp(args: [][]u8) i64 {
    if (args.len == 0) return 0;

    // Try datetime format "YYYY-MM-DD HH:MM:SS" (may span 2 args: date and time)
    if (args.len >= 2) {
        if (parse_datetime(args[0], args[1])) |ns| return ns;
    }

    // Fallback: integer nanoseconds
    return std.fmt.parseInt(i64, args[0], 10) catch 0;
}

fn parse_datetime(date_str: []const u8, time_str: []const u8) ?i64 {
    // Parse "YYYY-MM-DD"
    if (date_str.len != 10 or date_str[4] != '-' or date_str[7] != '-') return null;
    const year = std.fmt.parseInt(u16, date_str[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, date_str[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, date_str[8..10], 10) catch return null;

    // Parse "HH:MM:SS"
    if (time_str.len != 8 or time_str[2] != ':' or time_str[5] != ':') return null;
    const hour = std.fmt.parseInt(u8, time_str[0..2], 10) catch return null;
    const minute = std.fmt.parseInt(u8, time_str[3..5], 10) catch return null;
    const second = std.fmt.parseInt(u8, time_str[6..8], 10) catch return null;

    // Validate ranges
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    // Days from epoch (1970-01-01) to date
    const epoch_seconds = datetime_to_epoch(year, month, day, hour, minute, second);
    return epoch_seconds * 1_000_000_000; // Convert to nanoseconds
}

fn datetime_to_epoch(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    // Days in each month (non-leap)
    const days_in_month = [_]u16{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var days: i64 = 0;
    // Years since 1970
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (is_leap_year(y)) @as(i64, 366) else @as(i64, 365);
    }
    // Months
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += days_in_month[m - 1];
        if (m == 2 and is_leap_year(year)) days += 1;
    }
    // Days (1-indexed)
    days += day - 1;

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn is_leap_year(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn free_instruction_strings(allocator: std.mem.Allocator, instr: instruction.Instruction) void {
    switch (instr) {
        .set => |s| {
            allocator.free(s.identifier);
        },
        .rule_set => |r| {
            allocator.free(r.identifier);
            allocator.free(r.pattern);
            switch (r.runner) {
                .shell => |sh| allocator.free(sh.command),
                .amqp => |a| {
                    allocator.free(a.dsn);
                    allocator.free(a.exchange);
                    allocator.free(a.routing_key);
                },
            }
        },
        .get => |g| {
            allocator.free(g.identifier);
        },
    }
}

fn write_response(allocator: std.mem.Allocator, stream: std.net.Stream, resp: query.Response) !void {
    const status = if (resp.success) "OK" else "ERROR";
    const msg = if (resp.body) |body|
        try std.fmt.allocPrint(allocator, "{s} {s} {s}\n", .{ resp.request.identifier, status, body })
    else
        try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ resp.request.identifier, status });
    defer allocator.free(msg);
    _ = try stream.write(msg);
}

test "response router registers and deregisters clients" {
    var router = ResponseRouter.init(std.testing.allocator);
    defer router.deinit();

    var response_ch = try Channel(query.Response).init(std.testing.allocator, 1);
    defer response_ch.deinit();

    const client_id = @as(query.Client, 42);
    router.register(client_id, &response_ch);

    const req = query.Request{
        .client = client_id,
        .identifier = "test",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 0 } },
    };
    const resp = query.Response{ .request = req, .success = true };
    router.route(resp);

    const received = response_ch.try_receive();
    try std.testing.expect(received != null);

    router.deregister(client_id);
}

test "parse_timestamp parses integer nanoseconds" {
    const allocator = std.testing.allocator;
    var args_list = std.ArrayListUnmanaged([]u8){};
    defer args_list.deinit(allocator);
    try args_list.append(allocator, @constCast("1234567890"));

    const ts = parse_timestamp(args_list.items);
    try std.testing.expectEqual(@as(i64, 1234567890), ts);
}

test "parse_timestamp parses datetime format" {
    const allocator = std.testing.allocator;
    var args_list = std.ArrayListUnmanaged([]u8){};
    defer args_list.deinit(allocator);
    try args_list.append(allocator, @constCast("1970-01-01"));
    try args_list.append(allocator, @constCast("00:00:00"));

    const ts = parse_timestamp(args_list.items);
    try std.testing.expectEqual(@as(i64, 0), ts);
}

test "parse_timestamp returns zero on invalid input" {
    const allocator = std.testing.allocator;
    var args_list = std.ArrayListUnmanaged([]u8){};
    defer args_list.deinit(allocator);
    try args_list.append(allocator, @constCast("invalid"));

    const ts = parse_timestamp(args_list.items);
    try std.testing.expectEqual(@as(i64, 0), ts);
}

test "tcp server init stores address" {
    var running = std.atomic.Value(bool).init(true);
    var server = TcpServer.init(std.testing.allocator, "127.0.0.1:5678", &running);
    defer server.deinit();
    try std.testing.expectEqualStrings("127.0.0.1:5678", server.address);
}

test "build_instruction parses GET command with identifier" {
    var args = [_][]u8{ @constCast("GET"), @constCast("job.1") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .get => |g| try std.testing.expectEqualStrings("job.1", g.identifier),
        else => return error.WrongInstructionType,
    }
}

test "build_instruction returns null for GET without identifier" {
    var args = [_][]u8{@constCast("GET")};
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "free_instruction_strings frees GET identifier without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "job.1");
    const instr = instruction.Instruction{ .get = .{ .identifier = id } };
    free_instruction_strings(allocator, instr);
}

test "write_response appends body when response body is non-null" {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    const read_fd: std.posix.socket_t = @intCast(fds[0]);
    const write_fd: std.posix.socket_t = @intCast(fds[1]);
    defer std.posix.close(read_fd);

    const write_stream = std.net.Stream{ .handle = write_fd };

    const req = query.Request{
        .client = 0,
        .identifier = "req1",
        .instruction = .{ .get = .{ .identifier = "job.1" } },
    };
    const resp = query.Response{
        .request = req,
        .success = true,
        .body = "planned 1595586600000000000",
    };

    try write_response(std.testing.allocator, write_stream, resp);
    write_stream.close();

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(read_fd, &buf);
    try std.testing.expectEqualStrings("req1 OK planned 1595586600000000000\n", buf[0..n]);
}
