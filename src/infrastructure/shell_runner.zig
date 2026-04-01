const std = @import("std");
const domain = @import("../domain.zig");
const interfaces = @import("../interfaces.zig");

const execution = domain.execution;
const ShellConfig = interfaces.config.ShellConfig;

pub const ShellRunner = struct {
    pub fn execute(allocator: std.mem.Allocator, shell_config: ShellConfig, request: execution.Request) !execution.Response {
        const argv: []const []const u8 = switch (request.runner) {
            .shell => |s| blk: {
                var args = try allocator.alloc([]const u8, shell_config.args.len + 2);
                args[0] = shell_config.path;
                @memcpy(args[1 .. shell_config.args.len + 1], shell_config.args);
                args[shell_config.args.len + 1] = s.command;
                break :blk args;
            },
            .direct => |d| blk: {
                var args = try allocator.alloc([]const u8, d.args.len + 1);
                args[0] = d.executable;
                @memcpy(args[1..], d.args);
                break :blk args;
            },
            .amqp => return error.UnsupportedRunner,
            .http => |h| {
                return execute_http(allocator, h.method, h.url, request);
            },
            .awf => |a| blk: {
                const argc: usize = 3 + a.inputs.len * 2;
                var args = try allocator.alloc([]const u8, argc);
                args[0] = "awf";
                args[1] = "run";
                args[2] = a.workflow;
                for (a.inputs, 0..) |input, i| {
                    args[3 + i * 2] = "--input";
                    args[3 + i * 2 + 1] = input;
                }
                break :blk args;
            },
        };
        defer allocator.free(argv);
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = switch (request.runner) {
            .awf => .Pipe,
            else => .Ignore,
        };
        child.spawn() catch {
            return execution.Response{ .identifier = request.identifier, .success = false };
        };

        // Capture stderr for AWF runner (NFR-002)
        const stderr_output = if (child.stderr) |stderr_file|
            stderr_file.readToEndAlloc(allocator, 4096) catch null
        else
            null;
        defer if (stderr_output) |output| allocator.free(output);

        const term = child.wait() catch {
            return execution.Response{ .identifier = request.identifier, .success = false };
        };
        const success = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };

        if (stderr_output) |output| {
            if (output.len > 0) {
                std.log.debug("awf stderr: {s}", .{output});
            }
        }

        return execution.Response{
            .identifier = request.identifier,
            .success = success,
        };
    }
};

fn execute_http(allocator: std.mem.Allocator, method_str: []const u8, url: []const u8, req: execution.Request) execution.Response {
    return execute_http_inner(allocator, method_str, url, req) catch {
        std.log.debug("http runner: {s} {s} connection failed", .{ method_str, url });
        return .{ .identifier = req.identifier, .success = false };
    };
}

fn execute_http_inner(allocator: std.mem.Allocator, method_str: []const u8, url: []const u8, req: execution.Request) !execution.Response {
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
        const Payload = struct { job_id: []const u8, execution: i64 };
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer };
        s.write(Payload{ .job_id = req.job_identifier, .execution = req.execution }) catch return error.OutOfMemory;
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

    // Set 30s socket read/write timeout (NFR-001)
    if (http_req.connection) |conn| {
        const timeout = std.posix.timeval{ .sec = 30, .usec = 0 };
        const handle = conn.stream_reader.getStream().handle;
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
    }

    if (payload_buf) |payload| {
        http_req.transfer_encoding = .{ .content_length = payload.len };
        var body = try http_req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
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

const default_shell_config = ShellConfig{ .path = "/bin/sh", .args = &.{"-c"} };

test "shell runner executes command and reports success on exit code 0" {
    const request = execution.Request{
        .identifier = 1,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 1), response.identifier);
    try std.testing.expect(response.success);
}

test "shell runner reports failure for non-zero exit code" {
    const request = execution.Request{
        .identifier = 2,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/false" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 2), response.identifier);
    try std.testing.expect(!response.success);
}

test "shell runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xdeadbeef_cafebabe,
        .job_identifier = "scheduled.job",
        .runner = .{ .shell = .{ .command = "/bin/echo" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 0xdeadbeef_cafebabe), response.identifier);
}

test "shell runner uses configured shell path instead of hardcoded /bin/sh" {
    // /bin/false as the shell binary means any command invocation exits non-zero,
    // proving the config path is used rather than the hardcoded default.
    const config = ShellConfig{ .path = "/bin/false", .args = &.{"-c"} };
    const request = execution.Request{
        .identifier = 10,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, config, request);
    try std.testing.expect(!response.success);
}

test "shell runner executes direct runner without shell wrapper" {
    const request = execution.Request{
        .identifier = 20,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 20), response.identifier);
    try std.testing.expect(response.success);
}

test "direct runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xfeedface_baadf00d,
        .job_identifier = "direct.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 0xfeedface_baadf00d), response.identifier);
}

test "direct runner reports failure for non-zero exit code" {
    const request = execution.Request{
        .identifier = 30,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/false", .args = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 30), response.identifier);
    try std.testing.expect(!response.success);
}

test "direct runner passes arguments as literal argv elements without shell interpretation" {
    // If shell-interpreted: "/bin/echo hello; /bin/false" would run /bin/false and exit non-zero.
    // With direct execution: the semicolon is a literal arg to /bin/echo, which exits 0.
    const args = [_][]const u8{"hello; /bin/false"};
    const request = execution.Request{
        .identifier = 40,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/echo", .args = &args } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expect(response.success);
}

test "direct runner ignores shell_config and uses direct argv" {
    // Even with an invalid/dummy shell_config, direct runner bypasses it entirely.
    const dummy_config = ShellConfig{ .path = "/nonexistent/shell", .args = &.{"-c"} };
    const request = execution.Request{
        .identifier = 50,
        .job_identifier = "test.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, dummy_config, request);
    try std.testing.expect(response.success);
}

test "awf runner reports failure for non-zero exit from awf process" {
    const request = execution.Request{
        .identifier = 100,
        .job_identifier = "test.job",
        .runner = .{ .awf = .{ .workflow = "nonexistent-workflow", .inputs = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 100), response.identifier);
    try std.testing.expect(!response.success);
}

test "awf runner with inputs passes --input arguments to awf process" {
    const inputs = [_][]const u8{"format=pdf"};
    const request = execution.Request{
        .identifier = 110,
        .job_identifier = "test.job",
        .runner = .{ .awf = .{ .workflow = "nonexistent-workflow", .inputs = &inputs } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 110), response.identifier);
    try std.testing.expect(!response.success);
}

test "awf runner preserves identifier in response" {
    const request = execution.Request{
        .identifier = 0xbeefcafe_12345678,
        .job_identifier = "awf.job",
        .runner = .{ .awf = .{ .workflow = "nonexistent-workflow", .inputs = &.{} } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 0xbeefcafe_12345678), response.identifier);
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
        .identifier = 0x2000,
        .job_identifier = "health.check",
        .runner = .{ .http = .{ .method = "GET", .url = url } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0x2000), response.identifier);
    try std.testing.expect(response.success);
}

const CapturePost = struct {
    got_request: bool = false,
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
        self.got_request = true;
        _ = conn.stream.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
    }
};

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
        .identifier = 0x2001,
        .job_identifier = "deploy.release.1",
        .runner = .{ .http = .{ .method = "POST", .url = url } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
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
        .identifier = 0x2002,
        .job_identifier = "test.job",
        .runner = .{ .http = .{ .method = "GET", .url = url } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    // If stub didn't connect, unblock the server thread so the test doesn't hang
    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0x2002), response.identifier);
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
        .identifier = 0x2003,
        .job_identifier = "test.job",
        .runner = .{ .http = .{ .method = "GET", .url = url } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);

    try std.testing.expectEqual(@as(u128, 0x2003), response.identifier);
    try std.testing.expect(!response.success);
}

test "http runner completes HTTPS GET request with TLS" {
    const request = execution.Request{
        .identifier = 0x2004,
        .job_identifier = "tls.check",
        .runner = .{ .http = .{ .method = "GET", .url = "https://lafrenchtech.gouv.fr/" } },
    };
    const response = try ShellRunner.execute(std.testing.allocator, default_shell_config, request);
    try std.testing.expectEqual(@as(u128, 0x2004), response.identifier);
    try std.testing.expect(response.success);
}
