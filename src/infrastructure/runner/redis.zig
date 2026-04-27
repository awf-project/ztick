const std = @import("std");
const domain = @import("../../domain.zig");

const resp = @import("../redis/resp.zig");

const execution = domain.execution;

pub const RedisParseError = error{
    InvalidScheme,
    InvalidPort,
    InvalidDb,
    MissingHost,
};

pub const RedisDsn = struct {
    user: ?[]const u8,
    password: ?[]const u8,
    host: []const u8,
    port: u16,
    db: u8,
};

const redis_scheme = "redis://";

threadlocal var redact_buf: [2048]u8 = undefined;

pub fn parse_url(allocator: std.mem.Allocator, url: []const u8) RedisParseError!RedisDsn {
    _ = allocator;

    if (!std.mem.startsWith(u8, url, redis_scheme)) {
        return error.InvalidScheme;
    }

    const rest = url[redis_scheme.len..];

    var user: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var authority: []const u8 = rest;

    if (std.mem.indexOfScalar(u8, rest, '@')) |at_pos| {
        const userinfo = rest[0..at_pos];
        authority = rest[at_pos + 1 ..];

        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon_pos| {
            const u = userinfo[0..colon_pos];
            const p = userinfo[colon_pos + 1 ..];
            if (u.len > 0) user = u;
            if (p.len > 0) password = p;
        } else {
            if (userinfo.len > 0) user = userinfo;
        }
    }

    var host_and_port: []const u8 = authority;
    var db: u8 = 0;

    if (std.mem.indexOfScalar(u8, authority, '/')) |slash_pos| {
        host_and_port = authority[0..slash_pos];
        const db_str = authority[slash_pos + 1 ..];
        if (db_str.len > 0) {
            db = std.fmt.parseInt(u8, db_str, 10) catch return error.InvalidDb;
        }
    }

    var host: []const u8 = host_and_port;
    var port: u16 = 6379;

    if (std.mem.indexOfScalar(u8, host_and_port, ':')) |colon_pos| {
        host = host_and_port[0..colon_pos];
        const port_str = host_and_port[colon_pos + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
    }

    if (host.len == 0) {
        return error.MissingHost;
    }

    return RedisDsn{
        .user = user,
        .password = password,
        .host = host,
        .port = port,
        .db = db,
    };
}

pub fn redact_url(url: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, url, redis_scheme)) {
        return url;
    }

    const rest = url[redis_scheme.len..];
    if (std.mem.indexOfScalar(u8, rest, '@')) |at_pos| {
        const after_at = rest[at_pos + 1 ..];
        const total_len = redis_scheme.len + after_at.len;
        if (total_len <= redact_buf.len) {
            @memcpy(redact_buf[0..redis_scheme.len], redis_scheme);
            @memcpy(redact_buf[redis_scheme.len..total_len], after_at);
            return redact_buf[0..total_len];
        }
    }

    return url;
}

const NetReader = struct {
    stream: std.net.Stream,

    pub fn readByte(self: NetReader) !u8 {
        var b: [1]u8 = undefined;
        const n = try self.stream.read(&b);
        if (n == 0) return error.EndOfStream;
        return b[0];
    }

    pub fn readNoEof(self: NetReader, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.stream.read(buf[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    pub fn readUntilDelimiter(self: NetReader, buf: []u8, delimiter: u8) ![]u8 {
        var i: usize = 0;
        while (i < buf.len) {
            const b = try self.readByte();
            if (b == delimiter) return buf[0..i];
            buf[i] = b;
            i += 1;
        }
        return error.StreamTooLong;
    }

    pub fn readUntilDelimiterAlloc(self: NetReader, allocator: std.mem.Allocator, delimiter: u8, max_size: usize) ![]u8 {
        var list = std.ArrayListUnmanaged(u8){};
        errdefer list.deinit(allocator);
        while (list.items.len < max_size) {
            const b = try self.readByte();
            if (b == delimiter) return list.toOwnedSlice(allocator);
            try list.append(allocator, b);
        }
        return error.StreamTooLong;
    }

    pub fn skipBytes(self: NetReader, num_bytes: u64, comptime options: anytype) !void {
        _ = options;
        var remaining = num_bytes;
        while (remaining > 0) : (remaining -= 1) {
            _ = try self.readByte();
        }
    }
};

fn send_command(allocator: std.mem.Allocator, stream: std.net.Stream, items: []const []const u8) !void {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    try resp.encode_array(buf.writer(allocator), items);
    try stream.writeAll(buf.items);
}

fn read_reply(allocator: std.mem.Allocator, reader: NetReader) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = try resp.decode_value(arena.allocator(), reader);
    return switch (reply) {
        .error_msg => false,
        else => true,
    };
}

pub fn execute(
    allocator: std.mem.Allocator,
    payload: anytype,
    request: execution.Request,
) execution.Response {
    const failure = execution.Response{ .identifier = request.identifier, .success = false };

    const dsn = parse_url(allocator, payload.url) catch |err| {
        std.log.warn("redis runner: url parse failed: url={s} err={any}", .{ redact_url(payload.url), err });
        return failure;
    };

    const stream = std.net.tcpConnectToHost(allocator, dsn.host, dsn.port) catch |err| {
        std.log.warn("redis runner: tcp connect failed: url={s} err={any}", .{ redact_url(payload.url), err });
        return failure;
    };
    defer stream.close();

    const timeout = std.posix.timeval{ .sec = 30, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

    const reader = NetReader{ .stream = stream };

    if (dsn.password) |pass| {
        if (dsn.user) |user| {
            const items = [_][]const u8{ "AUTH", user, pass };
            send_command(allocator, stream, &items) catch |err| {
                std.log.warn("redis runner: AUTH send failed: url={s} err={any}", .{ redact_url(payload.url), err });
                return failure;
            };
        } else {
            const items = [_][]const u8{ "AUTH", pass };
            send_command(allocator, stream, &items) catch |err| {
                std.log.warn("redis runner: AUTH send failed: url={s} err={any}", .{ redact_url(payload.url), err });
                return failure;
            };
        }
        const ok = read_reply(allocator, reader) catch |err| {
            std.log.warn("redis runner: AUTH reply failed: url={s} err={any}", .{ redact_url(payload.url), err });
            return failure;
        };
        if (!ok) {
            std.log.warn("redis runner: AUTH rejected: url={s}", .{redact_url(payload.url)});
            return failure;
        }
    }

    if (dsn.db != 0) {
        var db_buf: [4]u8 = undefined;
        const db_str = std.fmt.bufPrint(&db_buf, "{d}", .{dsn.db}) catch unreachable;
        const items = [_][]const u8{ "SELECT", db_str };
        send_command(allocator, stream, &items) catch |err| {
            std.log.warn("redis runner: SELECT send failed: url={s} err={any}", .{ redact_url(payload.url), err });
            return failure;
        };
        const ok = read_reply(allocator, reader) catch |err| {
            std.log.warn("redis runner: SELECT reply failed: url={s} err={any}", .{ redact_url(payload.url), err });
            return failure;
        };
        if (!ok) {
            std.log.warn("redis runner: SELECT rejected: url={s}", .{redact_url(payload.url)});
            return failure;
        }
    }

    const cmd_items = [_][]const u8{ payload.command, payload.key, request.job_identifier };
    send_command(allocator, stream, &cmd_items) catch |err| {
        std.log.warn("redis runner: command send failed: url={s} err={any}", .{ redact_url(payload.url), err });
        return failure;
    };

    const ok = read_reply(allocator, reader) catch |err| {
        std.log.warn("redis runner: command reply failed: url={s} err={any}", .{ redact_url(payload.url), err });
        return failure;
    };
    if (!ok) {
        std.log.warn("redis runner: command error: url={s}", .{redact_url(payload.url)});
        return failure;
    }

    return .{ .identifier = request.identifier, .success = true };
}

test "parse_url extracts user password host port and db from full URL" {
    const dsn = try parse_url(std.testing.allocator, "redis://alice:s3cr3t@cache.example.com:6380/3");
    try std.testing.expectEqualStrings("alice", dsn.user.?);
    try std.testing.expectEqualStrings("s3cr3t", dsn.password.?);
    try std.testing.expectEqualStrings("cache.example.com", dsn.host);
    try std.testing.expectEqual(@as(u16, 6380), dsn.port);
    try std.testing.expectEqual(@as(u8, 3), dsn.db);
}

test "parse_url defaults port to 6379 and db to 0 when omitted" {
    const dsn = try parse_url(std.testing.allocator, "redis://localhost");
    try std.testing.expectEqualStrings("localhost", dsn.host);
    try std.testing.expectEqual(@as(u16, 6379), dsn.port);
    try std.testing.expectEqual(@as(u8, 0), dsn.db);
    try std.testing.expect(dsn.user == null);
    try std.testing.expect(dsn.password == null);
}

test "parse_url returns InvalidScheme for rediss scheme" {
    try std.testing.expectError(error.InvalidScheme, parse_url(std.testing.allocator, "rediss://localhost:6379/0"));
}

test "parse_url returns MissingHost when host segment is empty" {
    try std.testing.expectError(error.MissingHost, parse_url(std.testing.allocator, "redis:///0"));
}

test "redact_url strips userinfo from URL with credentials" {
    const redacted = redact_url("redis://alice:s3cr3t@cache.example.com:6379/0");
    try std.testing.expectEqualStrings("redis://cache.example.com:6379/0", redacted);
}

test "execute returns success=false on connection refused without raising" {
    const refused_port: u16 = blk: {
        const a = try std.net.Address.parseIp4("127.0.0.1", 0);
        var s = try a.listen(.{ .reuse_address = true });
        const p = s.listen_address.in.getPort();
        s.deinit();
        break :blk p;
    };
    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://127.0.0.1:{d}/0", .{refused_port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xBEEF5678,
        .job_identifier = "cache.miss.1",
        .runner = .{ .redis = .{ .url = url, .command = "PUBLISH", .key = "events" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);
    try std.testing.expectEqual(@as(u128, 0xBEEF5678), response.identifier);
    try std.testing.expect(!response.success);
}

test "execute preserves request identifier in response on every error path" {
    const request = execution.Request{
        .identifier = 0xDEADBEEF_CAFEBABE,
        .job_identifier = "preserve.id",
        .runner = .{ .redis = .{ .url = "not-a-redis-url", .command = "PUBLISH", .key = "ch" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);
    try std.testing.expectEqual(@as(u128, 0xDEADBEEF_CAFEBABE), response.identifier);
}

fn redis_peer_stub(server: *std.net.Server, reply: []const u8) void {
    var conn = server.accept() catch return;
    defer conn.stream.close();
    var discard: [4096]u8 = undefined;
    _ = conn.stream.read(&discard) catch {};
    conn.stream.writeAll(reply) catch {};
}

test "execute with RPUSH command pushes job identifier to redis list" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, redis_peer_stub, .{ &server, ":1\r\n" });

    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://127.0.0.1:{d}/0", .{port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xBBBB_1111,
        .job_identifier = "backup.nightly.1",
        .runner = .{ .redis = .{ .url = url, .command = "RPUSH", .key = "backup:tasks" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);

    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xBBBB_1111), response.identifier);
    try std.testing.expect(response.success);
}

test "execute with LPUSH command prepends job identifier to redis list" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, redis_peer_stub, .{ &server, ":1\r\n" });

    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://127.0.0.1:{d}/0", .{port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xCCCC_2222,
        .job_identifier = "backup.nightly.1",
        .runner = .{ .redis = .{ .url = url, .command = "LPUSH", .key = "backup:tasks" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);

    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xCCCC_2222), response.identifier);
    try std.testing.expect(response.success);
}

test "execute returns success=false when server replies with RESP error on queue command" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, redis_peer_stub, .{ &server, "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n" });

    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://127.0.0.1:{d}/0", .{port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xDDDD_3333,
        .job_identifier = "backup.nightly.1",
        .runner = .{ .redis = .{ .url = url, .command = "RPUSH", .key = "wrong:key" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);

    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xDDDD_3333), response.identifier);
    try std.testing.expect(!response.success);
}

test "parse_url returns InvalidScheme for non-redis scheme" {
    try std.testing.expectError(error.InvalidScheme, parse_url(std.testing.allocator, "http://localhost:6379/0"));
}

test "parse_url returns InvalidPort for non-numeric port" {
    try std.testing.expectError(error.InvalidPort, parse_url(std.testing.allocator, "redis://localhost:abc/0"));
}

test "parse_url returns InvalidDb when db exceeds u8 range" {
    try std.testing.expectError(error.InvalidDb, parse_url(std.testing.allocator, "redis://localhost:6379/256"));
}

test "parse_url accepts empty username for legacy single-arg AUTH" {
    const dsn = try parse_url(std.testing.allocator, "redis://:secretpass@localhost:6379/0");
    try std.testing.expect(dsn.user == null);
    try std.testing.expectEqualStrings("secretpass", dsn.password.?);
}

test "redact_url passes through URL with no userinfo unchanged" {
    const result = redact_url("redis://localhost:6379/0");
    try std.testing.expectEqualStrings("redis://localhost:6379/0", result);
}

fn redis_multi_stub_2(server: *std.net.Server, r1: []const u8, r2: []const u8) void {
    var conn = server.accept() catch return;
    defer conn.stream.close();
    var buf: [4096]u8 = undefined;
    _ = conn.stream.read(&buf) catch return;
    conn.stream.writeAll(r1) catch return;
    _ = conn.stream.read(&buf) catch return;
    conn.stream.writeAll(r2) catch return;
}

fn redis_multi_stub_3(server: *std.net.Server, r1: []const u8, r2: []const u8, r3: []const u8) void {
    var conn = server.accept() catch return;
    defer conn.stream.close();
    var buf: [4096]u8 = undefined;
    _ = conn.stream.read(&buf) catch return;
    conn.stream.writeAll(r1) catch return;
    _ = conn.stream.read(&buf) catch return;
    conn.stream.writeAll(r2) catch return;
    _ = conn.stream.read(&buf) catch return;
    conn.stream.writeAll(r3) catch return;
}

test "execute with two-arg AUTH sends credentials and command successfully" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, redis_multi_stub_2, .{ &server, "+OK\r\n", ":1\r\n" });

    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://alice:s3cr3t@127.0.0.1:{d}/0", .{port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xAA11_0001,
        .job_identifier = "auth.test.1",
        .runner = .{ .redis = .{ .url = url, .command = "PUBLISH", .key = "events" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);

    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xAA11_0001), response.identifier);
    try std.testing.expect(response.success);
}

test "execute with single-arg AUTH sends password only and command successfully" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, redis_multi_stub_2, .{ &server, "+OK\r\n", ":1\r\n" });

    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://:s3cr3t@127.0.0.1:{d}/0", .{port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xAA11_0002,
        .job_identifier = "auth.test.2",
        .runner = .{ .redis = .{ .url = url, .command = "PUBLISH", .key = "events" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);

    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xAA11_0002), response.identifier);
    try std.testing.expect(response.success);
}

test "execute returns success=false when AUTH is rejected by server" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, redis_peer_stub, .{ &server, "-WRONGPASS invalid username-password pair or user is disabled.\r\n" });

    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://alice:wrongpass@127.0.0.1:{d}/0", .{port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xAA11_0003,
        .job_identifier = "auth.test.3",
        .runner = .{ .redis = .{ .url = url, .command = "PUBLISH", .key = "events" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);

    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xAA11_0003), response.identifier);
    try std.testing.expect(!response.success);
}

test "execute sends SELECT when db is non-zero and command succeeds" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, redis_multi_stub_2, .{ &server, "+OK\r\n", ":1\r\n" });

    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://127.0.0.1:{d}/3", .{port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xAA11_0004,
        .job_identifier = "select.test.1",
        .runner = .{ .redis = .{ .url = url, .command = "PUBLISH", .key = "events" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);

    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xAA11_0004), response.identifier);
    try std.testing.expect(response.success);
}

test "execute returns success=false when SELECT is rejected by server" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, redis_peer_stub, .{ &server, "-ERR DB index is out of range\r\n" });

    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://127.0.0.1:{d}/16", .{port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xAA11_0005,
        .job_identifier = "select.test.2",
        .runner = .{ .redis = .{ .url = url, .command = "PUBLISH", .key = "events" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);

    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xAA11_0005), response.identifier);
    try std.testing.expect(!response.success);
}

test "execute with credentials and non-zero db sends AUTH then SELECT then command" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, redis_multi_stub_3, .{ &server, "+OK\r\n", "+OK\r\n", ":1\r\n" });

    const url = try std.fmt.allocPrint(std.testing.allocator, "redis://alice:s3cr3t@127.0.0.1:{d}/3", .{port});
    defer std.testing.allocator.free(url);
    const request = execution.Request{
        .identifier = 0xAA11_0006,
        .job_identifier = "auth.select.test.1",
        .runner = .{ .redis = .{ .url = url, .command = "PUBLISH", .key = "events" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);

    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xAA11_0006), response.identifier);
    try std.testing.expect(response.success);
}

test "redis runner publishes job identifier to channel" {
    const build_options = @import("build_options");
    if (!build_options.redis_integration) return error.SkipZigTest;

    const address = try std.net.Address.parseIp4("127.0.0.1", 6379);
    const probe = std.net.tcpConnectToAddress(address) catch return error.SkipZigTest;
    probe.close();

    const request = execution.Request{
        .identifier = 0xA1B2_C3D4_E5F6_0718,
        .job_identifier = "ztick.redis.integration.test",
        .runner = .{ .redis = .{ .url = "redis://127.0.0.1:6379/0", .command = "PUBLISH", .key = "ztick:integration" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);
    try std.testing.expectEqual(@as(u128, 0xA1B2_C3D4_E5F6_0718), response.identifier);
    try std.testing.expect(response.success);
}

test "redis runner pushes job identifier to list tail with RPUSH" {
    const build_options = @import("build_options");
    if (!build_options.redis_integration) return error.SkipZigTest;

    const address = try std.net.Address.parseIp4("127.0.0.1", 6379);
    const probe = std.net.tcpConnectToAddress(address) catch return error.SkipZigTest;
    probe.close();

    const request = execution.Request{
        .identifier = 0xA1B2_C3D4_E5F6_0719,
        .job_identifier = "ztick.redis.integration.rpush",
        .runner = .{ .redis = .{ .url = "redis://127.0.0.1:6379/0", .command = "RPUSH", .key = "ztick:integration:queue" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);
    try std.testing.expectEqual(@as(u128, 0xA1B2_C3D4_E5F6_0719), response.identifier);
    try std.testing.expect(response.success);
}

test "redis runner SET command stores job identifier at key" {
    const build_options = @import("build_options");
    if (!build_options.redis_integration) return error.SkipZigTest;

    const address = try std.net.Address.parseIp4("127.0.0.1", 6379);
    const probe = std.net.tcpConnectToAddress(address) catch return error.SkipZigTest;
    probe.close();

    const request = execution.Request{
        .identifier = 0xA1B2_C3D4_E5F6_0720,
        .job_identifier = "ztick.redis.integration.set",
        .runner = .{ .redis = .{ .url = "redis://127.0.0.1:6379/0", .command = "SET", .key = "ztick:integration:set_key" } },
    };
    const response = execute(std.testing.allocator, request.runner.redis, request);
    try std.testing.expectEqual(@as(u128, 0xA1B2_C3D4_E5F6_0720), response.identifier);
    try std.testing.expect(response.success);
}

test "redis runner RPUSH round-trip confirms job identifier at list tail via LRANGE" {
    const build_options = @import("build_options");
    if (!build_options.redis_integration) return error.SkipZigTest;

    const address = try std.net.Address.parseIp4("127.0.0.1", 6379);
    const probe = std.net.tcpConnectToAddress(address) catch return error.SkipZigTest;
    probe.close();

    const job_id = "ztick.redis.integration.lrange.verify";
    const list_key = "ztick:integration:lrange:roundtrip";

    const push_request = execution.Request{
        .identifier = 0xA1B2_C3D4_E5F6_0721,
        .job_identifier = job_id,
        .runner = .{ .redis = .{ .url = "redis://127.0.0.1:6379/0", .command = "RPUSH", .key = list_key } },
    };
    const push_response = execute(std.testing.allocator, push_request.runner.redis, push_request);
    try std.testing.expect(push_response.success);

    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    var cmd_buf = std.ArrayListUnmanaged(u8){};
    defer cmd_buf.deinit(std.testing.allocator);
    const lrange_items = [_][]const u8{ "LRANGE", list_key, "0", "-1" };
    try resp.encode_array(cmd_buf.writer(std.testing.allocator), &lrange_items);
    try stream.writeAll(cmd_buf.items);

    const net_reader = NetReader{ .stream = stream };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const reply = try resp.decode_value(arena.allocator(), net_reader);

    const arr = switch (reply) {
        .array => |a| a,
        else => return error.UnexpectedReplyType,
    };
    var found = false;
    for (arr) |item| {
        switch (item) {
            .bulk_string => |bs| if (bs) |s| if (std.mem.eql(u8, s, job_id)) {
                found = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found);
}
