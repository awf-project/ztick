const std = @import("std");
const domain = @import("../../domain.zig");

const execution = domain.execution;

pub fn execute(allocator: std.mem.Allocator, payload: anytype, request: execution.Request) execution.Response {
    return execute_inner(allocator, payload.method, payload.url, request) catch {
        std.log.debug("http runner: {s} {s} connection failed", .{ payload.method, payload.url });
        return .{ .identifier = request.identifier, .success = false };
    };
}

fn execute_inner(allocator: std.mem.Allocator, method_str: []const u8, url: []const u8, req: execution.Request) !execution.Response {
    const method: std.http.Method = if (std.mem.eql(u8, method_str, "GET"))
        .GET
    else if (std.mem.eql(u8, method_str, "POST"))
        .POST
    else if (std.mem.eql(u8, method_str, "PUT"))
        .PUT
    else if (std.mem.eql(u8, method_str, "DELETE"))
        .DELETE
    else
        return .{ .identifier = req.identifier, .success = false };

    const has_body = method == .POST or method == .PUT;

    var payload_buf: ?[]u8 = null;
    defer if (payload_buf) |b| allocator.free(b);

    if (has_body) {
        const Body = struct { job_id: []const u8, execution: i64 };
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        s.write(Body{ .job_id = req.job_identifier, .execution = req.execution }) catch return error.OutOfMemory;
        payload_buf = try out.toOwnedSlice();
    }

    const extra_headers: []const std.http.Header = if (has_body)
        &[_]std.http.Header{.{ .name = "Content-Type", .value = "application/json" }}
    else
        &.{};

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var http_req = try client.request(method, uri, .{
        .extra_headers = extra_headers,
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer http_req.deinit();

    if (http_req.connection) |conn| {
        const timeout = std.posix.timeval{ .sec = 30, .usec = 0 };
        const handle = conn.stream_reader.getStream().handle;
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
    }

    if (payload_buf) |body| {
        http_req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try http_req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try http_req.connection.?.flush();
    } else {
        try http_req.sendBodiless();
    }

    var response = try http_req.receiveHead(&.{});
    const reader = response.reader(&.{});
    _ = reader.discardRemaining() catch {};

    const status = response.head.status;
    if (status.class() != .success) {
        std.log.debug("http runner: {s} {s} returned {d}", .{ method_str, url, @intFromEnum(status) });
    }

    return .{ .identifier = req.identifier, .success = status.class() == .success };
}

const SimpleServer = struct {
    response: []const u8,

    fn run(self: @This(), s: *std.net.Server) void {
        var conn = s.accept() catch return;
        defer conn.stream.close();
        var buf: [4096]u8 = undefined;
        _ = conn.stream.read(&buf) catch {};
        _ = conn.stream.writeAll(self.response) catch {};
    }
};

const CapturePost = struct {
    body: [1024]u8 = undefined,
    body_len: usize = 0,

    fn run(self: *@This(), s: *std.net.Server) void {
        var conn = s.accept() catch return;
        defer conn.stream.close();
        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = conn.stream.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |he| {
                const body = buf[he + 4 .. total];
                const len = @min(body.len, self.body.len);
                @memcpy(self.body[0..len], body[0..len]);
                self.body_len = len;
                break;
            }
        }
        _ = conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
    }
};

test "http runner reports success for GET request with 2xx response" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const srv = SimpleServer{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
    const t = try std.Thread.spawn(.{}, SimpleServer.run, .{ srv, &server });

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/webhook", .{port});
    defer std.testing.allocator.free(url);

    const request = execution.Request{
        .identifier = 0x3000,
        .job_identifier = "health.check",
        .runner = .{ .http = .{ .method = "GET", .url = url } },
    };
    const response = execute(std.testing.allocator, request.runner.http, request);
    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0x3000), response.identifier);
    try std.testing.expect(response.success);
}

test "http runner sends json body for POST request and reports success on 2xx response" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    var capture = CapturePost{};
    const t = try std.Thread.spawn(.{}, CapturePost.run, .{ &capture, &server });

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/notify", .{port});
    defer std.testing.allocator.free(url);

    const request = execution.Request{
        .identifier = 0x3001,
        .job_identifier = "deploy.release.1",
        .runner = .{ .http = .{ .method = "POST", .url = url } },
    };
    const response = execute(std.testing.allocator, request.runner.http, request);
    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expect(response.success);
    const body = capture.body[0..capture.body_len];
    try std.testing.expect(std.mem.indexOf(u8, body, "\"job_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "deploy.release.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"execution\"") != null);
}

test "http runner reports failure for non-2xx response" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const srv = SimpleServer{ .response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
    const t = try std.Thread.spawn(.{}, SimpleServer.run, .{ srv, &server });

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/hook", .{port});
    defer std.testing.allocator.free(url);

    const request = execution.Request{
        .identifier = 0x3002,
        .job_identifier = "test.job",
        .runner = .{ .http = .{ .method = "GET", .url = url } },
    };
    const response = execute(std.testing.allocator, request.runner.http, request);
    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0x3002), response.identifier);
    try std.testing.expect(!response.success);
}

test "http runner reports failure when connection refused" {
    const refused_port: u16 = blk: {
        const a = try std.net.Address.parseIp4("127.0.0.1", 0);
        var s = try a.listen(.{ .reuse_address = true });
        const p = s.listen_address.in.getPort();
        s.deinit();
        break :blk p;
    };
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/webhook", .{refused_port});
    defer std.testing.allocator.free(url);

    const request = execution.Request{
        .identifier = 0x3003,
        .job_identifier = "test.job",
        .runner = .{ .http = .{ .method = "GET", .url = url } },
    };
    const response = execute(std.testing.allocator, request.runner.http, request);

    try std.testing.expectEqual(@as(u128, 0x3003), response.identifier);
    try std.testing.expect(!response.success);
}
