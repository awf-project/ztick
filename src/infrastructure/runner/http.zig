const std = @import("std");
const domain = @import("../../domain.zig");

const execution = domain.execution;

pub fn execute(io: std.Io, allocator: std.mem.Allocator, payload: anytype, request: execution.Request) execution.Response {
    return execute_inner(io, allocator, payload.method, payload.url, request) catch {
        std.log.debug("http runner: {s} {s} connection failed", .{ payload.method, payload.url });
        return .{ .identifier = request.identifier, .success = false };
    };
}

fn execute_inner(io: std.Io, allocator: std.mem.Allocator, method_str: []const u8, url: []const u8, req: execution.Request) !execution.Response {
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

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var http_req = try client.request(method, uri, .{
        .extra_headers = extra_headers,
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer http_req.deinit();

    var redirect_buf: [4096]u8 = undefined;
    if (payload_buf) |body| {
        var body_buf: [65536]u8 = undefined;
        http_req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try http_req.sendBodyUnflushed(&body_buf);
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try http_req.connection.?.flush();
    } else {
        try http_req.sendBodiless();
    }

    var response = try http_req.receiveHead(&redirect_buf);
    var transfer_buf: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    _ = reader.discardRemaining() catch {};

    const status = response.head.status;
    if (status.class() != .success) {
        std.log.debug("http runner: {s} {s} returned {d}", .{ method_str, url, @intFromEnum(status) });
    }

    return .{ .identifier = req.identifier, .success = status.class() == .success };
}

const SimpleServer = struct {
    response: []const u8,

    fn run(self: @This(), s: *std.Io.net.Server) void {
        const io = std.testing.io;
        const conn = s.accept(io) catch return;
        defer _ = std.os.linux.close(conn.socket.handle);
        var buf: [4096]u8 = undefined;
        const n = blk: {
            const rc = std.os.linux.read(conn.socket.handle, &buf, buf.len);
            break :blk if (@as(isize, @bitCast(rc)) < 0) 0 else rc;
        };
        _ = n;
        _ = std.os.linux.write(conn.socket.handle, self.response.ptr, self.response.len);
    }
};

const CapturePost = struct {
    body: [1024]u8 = undefined,
    body_len: usize = 0,

    fn run(self: *@This(), s: *std.Io.net.Server) void {
        const io = std.testing.io;
        const conn = s.accept(io) catch return;
        defer _ = std.os.linux.close(conn.socket.handle);
        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const rc = std.os.linux.read(conn.socket.handle, buf[total..].ptr, buf.len - total);
            const n = if (@as(isize, @bitCast(rc)) < 0) break else rc;
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
        const ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _ = std.os.linux.write(conn.socket.handle, ok.ptr, ok.len);
    }
};

test "http runner reports success for GET request with 2xx response" {
    const io = std.testing.io;
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    const listen_addr = server.socket.address;
    defer server.deinit(io);
    const port = listen_addr.getPort();

    const srv = SimpleServer{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
    const t = try std.Thread.spawn(.{}, SimpleServer.run, .{ srv, &server });

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/webhook", .{port});
    defer std.testing.allocator.free(url);

    const request = execution.Request{
        .identifier = 0x3000,
        .job_identifier = "health.check",
        .runner = .{ .http = .{ .method = "GET", .url = url } },
    };
    const response = execute(io, std.testing.allocator, request.runner.http, request);
    if (std.Io.net.IpAddress.connect(&listen_addr, io, .{ .mode = .stream })) |c| _ = std.os.linux.close(c.socket.handle) else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0x3000), response.identifier);
    try std.testing.expect(response.success);
}

test "http runner sends json body for POST request and reports success on 2xx response" {
    const io = std.testing.io;
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    const listen_addr = server.socket.address;
    defer server.deinit(io);
    const port = listen_addr.getPort();

    var capture = CapturePost{};
    const t = try std.Thread.spawn(.{}, CapturePost.run, .{ &capture, &server });

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/notify", .{port});
    defer std.testing.allocator.free(url);

    const request = execution.Request{
        .identifier = 0x3001,
        .job_identifier = "deploy.release.1",
        .runner = .{ .http = .{ .method = "POST", .url = url } },
    };
    const response = execute(io, std.testing.allocator, request.runner.http, request);
    if (std.Io.net.IpAddress.connect(&listen_addr, io, .{ .mode = .stream })) |c| _ = std.os.linux.close(c.socket.handle) else |_| {}
    t.join();

    try std.testing.expect(response.success);
    const body = capture.body[0..capture.body_len];
    try std.testing.expect(std.mem.indexOf(u8, body, "\"job_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "deploy.release.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"execution\"") != null);
}

test "http runner reports failure for non-2xx response" {
    const io = std.testing.io;
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    const listen_addr = server.socket.address;
    defer server.deinit(io);
    const port = listen_addr.getPort();

    const srv = SimpleServer{ .response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" };
    const t = try std.Thread.spawn(.{}, SimpleServer.run, .{ srv, &server });

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/hook", .{port});
    defer std.testing.allocator.free(url);

    const request = execution.Request{
        .identifier = 0x3002,
        .job_identifier = "test.job",
        .runner = .{ .http = .{ .method = "GET", .url = url } },
    };
    const response = execute(io, std.testing.allocator, request.runner.http, request);
    if (std.Io.net.IpAddress.connect(&listen_addr, io, .{ .mode = .stream })) |c| _ = std.os.linux.close(c.socket.handle) else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0x3002), response.identifier);
    try std.testing.expect(!response.success);
}

test "http runner reports failure when connection refused" {
    const io = std.testing.io;
    const refused_port: u16 = blk: {
        var a = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var s = try std.Io.net.IpAddress.listen(&a, io, .{ .reuse_address = true });
        const p = s.socket.address.getPort();
        s.deinit(io);
        break :blk p;
    };
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/webhook", .{refused_port});
    defer std.testing.allocator.free(url);

    const request = execution.Request{
        .identifier = 0x3003,
        .job_identifier = "test.job",
        .runner = .{ .http = .{ .method = "GET", .url = url } },
    };
    const response = execute(io, std.testing.allocator, request.runner.http, request);

    try std.testing.expectEqual(@as(u128, 0x3003), response.identifier);
    try std.testing.expect(!response.success);
}
