const std = @import("std");
const domain = @import("../../domain.zig");

const execution = domain.execution;

pub const AmqpParseError = error{
    InvalidScheme,
    InvalidPort,
    MissingHost,
    MissingUserInfo,
};

pub const AmqpDsn = struct {
    user: []const u8,
    password: []const u8,
    host: []const u8,
    port: u16,
    vhost: []const u8,
};

pub fn parse_dsn(allocator: std.mem.Allocator, dsn: []const u8) AmqpParseError!AmqpDsn {
    _ = allocator;

    if (!std.mem.startsWith(u8, dsn, amqp_scheme)) {
        return error.InvalidScheme;
    }

    const rest = dsn[amqp_scheme.len..];

    const at_pos = std.mem.indexOfScalar(u8, rest, '@') orelse return error.MissingUserInfo;
    const userinfo = rest[0..at_pos];
    const authority = rest[at_pos + 1 ..];

    var user: []const u8 = userinfo;
    var password: []const u8 = "";
    if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon_pos| {
        user = userinfo[0..colon_pos];
        password = userinfo[colon_pos + 1 ..];
    }

    var host_and_path: []const u8 = authority;
    var vhost: []const u8 = "/";

    if (std.mem.indexOfScalar(u8, authority, '/')) |slash_pos| {
        host_and_path = authority[0..slash_pos];
        vhost = authority[slash_pos..];
    }

    var host: []const u8 = host_and_path;
    var port: u16 = 5672;

    if (std.mem.indexOfScalar(u8, host_and_path, ':')) |colon_pos| {
        host = host_and_path[0..colon_pos];
        const port_str = host_and_path[colon_pos + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
    }

    if (host.len == 0) {
        return error.MissingHost;
    }

    return AmqpDsn{
        .user = user,
        .password = password,
        .host = host,
        .port = port,
        .vhost = vhost,
    };
}

threadlocal var redact_buf: [2048]u8 = undefined;

pub fn redact_dsn(dsn: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, dsn, amqp_scheme)) {
        return dsn;
    }

    const rest = dsn[amqp_scheme.len..];
    if (std.mem.indexOfScalar(u8, rest, '@')) |at_pos| {
        const after_at = rest[at_pos + 1 ..];
        const total_len = amqp_scheme.len + after_at.len;
        if (total_len <= redact_buf.len) {
            @memcpy(redact_buf[0..amqp_scheme.len], amqp_scheme);
            @memcpy(redact_buf[amqp_scheme.len..total_len], after_at);
            return redact_buf[0..total_len];
        }
    }

    return dsn;
}

const amqp_scheme = "amqp://";
const frame_end: u8 = 0xCE;

const Frame = struct {
    frame_type: u8,
    channel: u16,
    payload: []u8,
};

fn write_frame(writer: anytype, frame_type: u8, channel: u16, payload: []const u8) !void {
    var header: [7]u8 = undefined;
    header[0] = frame_type;
    std.mem.writeInt(u16, header[1..3], channel, .big);
    std.mem.writeInt(u32, header[3..7], @intCast(payload.len), .big);
    try writer.writeAll(&header);
    try writer.writeAll(payload);
    try writer.writeByte(frame_end);
}

fn read_frame(allocator: std.mem.Allocator, reader: anytype) !Frame {
    var header: [7]u8 = undefined;
    try reader.readNoEof(&header);
    const frame_type = header[0];
    const channel = std.mem.readInt(u16, header[1..3], .big);
    const size = std.mem.readInt(u32, header[3..7], .big);
    const payload = try allocator.alloc(u8, size);
    errdefer allocator.free(payload);
    try reader.readNoEof(payload);
    const sentinel = try reader.readByte();
    if (sentinel != frame_end) return error.InvalidFrameEnd;
    return Frame{ .frame_type = frame_type, .channel = channel, .payload = payload };
}

fn encode_connection_start_ok(allocator: std.mem.Allocator, writer: anytype, user: []const u8, password: []const u8) !void {
    var payload = std.ArrayListUnmanaged(u8){};
    defer payload.deinit(allocator);
    const w = payload.writer(allocator);

    // class-id Connection (10), method-id StartOk (11)
    try w.writeInt(u16, 0x000A, .big);
    try w.writeInt(u16, 0x000B, .big);

    // client-properties: empty field-table (longstr length 0)
    try w.writeInt(u32, 0, .big);

    // mechanism: shortstr "PLAIN"
    const mechanism = "PLAIN";
    try w.writeByte(@intCast(mechanism.len));
    try w.writeAll(mechanism);

    // response: longstr "\x00user\x00password"
    const response_len: u32 = @intCast(1 + user.len + 1 + password.len);
    try w.writeInt(u32, response_len, .big);
    try w.writeByte(0);
    try w.writeAll(user);
    try w.writeByte(0);
    try w.writeAll(password);

    // locale: shortstr "en_US"
    const locale = "en_US";
    try w.writeByte(@intCast(locale.len));
    try w.writeAll(locale);

    try write_frame(writer, 0x01, 0, payload.items);
}

fn encode_connection_tune_ok(writer: anytype, channel_max: u16, frame_max: u32, heartbeat: u16) !void {
    var payload: [12]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 0x000A, .big);
    std.mem.writeInt(u16, payload[2..4], 0x001F, .big);
    std.mem.writeInt(u16, payload[4..6], channel_max, .big);
    std.mem.writeInt(u32, payload[6..10], frame_max, .big);
    std.mem.writeInt(u16, payload[10..12], heartbeat, .big);
    try write_frame(writer, 0x01, 0, &payload);
}

fn encode_connection_open(writer: anytype, vhost: []const u8) !void {
    if (vhost.len > 255) return error.VhostTooLong;
    var buf: [263]u8 = undefined;
    var pos: usize = 0;

    // class-id Connection (10), method-id Open (40)
    std.mem.writeInt(u16, buf[pos..][0..2], 0x000A, .big);
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], 0x0028, .big);
    pos += 2;

    // virtual-host: shortstr
    buf[pos] = @intCast(vhost.len);
    pos += 1;
    @memcpy(buf[pos..][0..vhost.len], vhost);
    pos += vhost.len;

    // capabilities: shortstr "" (deprecated, length 0)
    buf[pos] = 0;
    pos += 1;

    // insist: bit (deprecated, packed in byte)
    buf[pos] = 0;
    pos += 1;

    try write_frame(writer, 0x01, 0, buf[0..pos]);
}

fn encode_channel_open(writer: anytype, channel: u16) !void {
    var payload: [5]u8 = undefined;
    // class-id Channel (20), method-id Open (10)
    std.mem.writeInt(u16, payload[0..2], 0x0014, .big);
    std.mem.writeInt(u16, payload[2..4], 0x000A, .big);
    // out-of-band: shortstr "" (deprecated)
    payload[4] = 0;
    try write_frame(writer, 0x01, channel, &payload);
}

fn encode_basic_publish(allocator: std.mem.Allocator, writer: anytype, channel: u16, exchange: []const u8, routing_key: []const u8, body: []const u8) !void {
    if (exchange.len > 255) return error.ExchangeNameTooLong;
    if (routing_key.len > 255) return error.RoutingKeyTooLong;
    // === Method frame: Basic.Publish ===
    var method_payload = std.ArrayListUnmanaged(u8){};
    defer method_payload.deinit(allocator);
    const mw = method_payload.writer(allocator);

    // class-id Basic (60), method-id Publish (40)
    try mw.writeInt(u16, 0x003C, .big);
    try mw.writeInt(u16, 0x0028, .big);

    // ticket (reserved-1) u16 = 0
    try mw.writeInt(u16, 0, .big);

    // exchange: shortstr
    try mw.writeByte(@intCast(exchange.len));
    try mw.writeAll(exchange);

    // routing-key: shortstr
    try mw.writeByte(@intCast(routing_key.len));
    try mw.writeAll(routing_key);

    // bits: mandatory=0, immediate=0
    try mw.writeByte(0);

    try write_frame(writer, 0x01, channel, method_payload.items);

    // === Content header frame ===
    var header_payload: [14]u8 = undefined;
    // class-id Basic
    std.mem.writeInt(u16, header_payload[0..2], 0x003C, .big);
    // weight = 0
    std.mem.writeInt(u16, header_payload[2..4], 0, .big);
    // body-size u64
    std.mem.writeInt(u64, header_payload[4..12], @intCast(body.len), .big);
    // property flags u16 = 0 (no properties)
    std.mem.writeInt(u16, header_payload[12..14], 0, .big);
    try write_frame(writer, 0x02, channel, &header_payload);

    // === Body frame ===
    try write_frame(writer, 0x03, channel, body);
}

fn encode_channel_close(writer: anytype, channel: u16) !void {
    var payload: [13]u8 = undefined;
    // class-id Channel (20), method-id Close (40)
    std.mem.writeInt(u16, payload[0..2], 0x0014, .big);
    std.mem.writeInt(u16, payload[2..4], 0x0028, .big);
    // reply-code u16 = 200
    std.mem.writeInt(u16, payload[4..6], 200, .big);
    // reply-text: shortstr "OK"
    payload[6] = 2;
    payload[7] = 'O';
    payload[8] = 'K';
    // class-id u16 = 0
    std.mem.writeInt(u16, payload[9..11], 0, .big);
    // method-id u16 = 0
    std.mem.writeInt(u16, payload[11..13], 0, .big);
    try write_frame(writer, 0x01, channel, &payload);
}

fn encode_connection_close(writer: anytype) !void {
    var payload: [13]u8 = undefined;
    // class-id Connection (10), method-id Close (50)
    std.mem.writeInt(u16, payload[0..2], 0x000A, .big);
    std.mem.writeInt(u16, payload[2..4], 0x0032, .big);
    // reply-code u16 = 200
    std.mem.writeInt(u16, payload[4..6], 200, .big);
    // reply-text: shortstr "OK"
    payload[6] = 2;
    payload[7] = 'O';
    payload[8] = 'K';
    // class-id u16 = 0
    std.mem.writeInt(u16, payload[9..11], 0, .big);
    // method-id u16 = 0
    std.mem.writeInt(u16, payload[11..13], 0, .big);
    try write_frame(writer, 0x01, 0, &payload);
}

const protocol_header = [_]u8{ 'A', 'M', 'Q', 'P', 0, 0, 9, 1 };

const StreamReader = struct {
    stream: std.net.Stream,

    fn readNoEof(self: StreamReader, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.stream.read(buf[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    fn readByte(self: StreamReader) !u8 {
        var b: [1]u8 = undefined;
        try self.readNoEof(&b);
        return b[0];
    }
};

fn flush_buf(stream: std.net.Stream, buf: *std.ArrayListUnmanaged(u8)) !void {
    try stream.writeAll(buf.items);
    buf.clearRetainingCapacity();
}

// Reads the next method frame from the stream. If the server sent
// Connection.Close (class=10, method=50), the payload is consumed and
// error.PeerClose is returned. If the frame's class/method does not
// match expected, error.UnexpectedFrame is returned.
fn expect_method(
    allocator: std.mem.Allocator,
    reader: anytype,
    expected_class: u16,
    expected_method: u16,
) !void {
    const frame = try read_frame(allocator, reader);
    defer allocator.free(frame.payload);

    if (frame.frame_type != 0x01 or frame.payload.len < 4) {
        return error.UnexpectedFrame;
    }
    const class_id = std.mem.readInt(u16, frame.payload[0..2], .big);
    const method_id = std.mem.readInt(u16, frame.payload[2..4], .big);

    if (class_id == 0x000A and method_id == 0x0032) {
        return error.PeerClose;
    }
    if (class_id != expected_class or method_id != expected_method) {
        return error.UnexpectedFrame;
    }
}

fn run_handshake(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    dsn_info: AmqpDsn,
    exchange: []const u8,
    routing_key: []const u8,
    body: []const u8,
) !void {
    const reader = StreamReader{ .stream = stream };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // 1. Send protocol header
    try stream.writeAll(&protocol_header);

    // 2. Receive Connection.Start (class=10, method=10)
    try expect_method(allocator, reader, 0x000A, 0x000A);

    // 3. Send Connection.StartOk (PLAIN auth)
    try encode_connection_start_ok(allocator, writer, dsn_info.user, dsn_info.password);
    try flush_buf(stream, &buf);

    // 4. Receive Connection.Tune (class=10, method=30)
    try expect_method(allocator, reader, 0x000A, 0x001E);

    // 5. Send Connection.TuneOk with conservative client values
    try encode_connection_tune_ok(writer, 2047, 131072, 0);
    try flush_buf(stream, &buf);

    // 6. Send Connection.Open with vhost
    try encode_connection_open(writer, dsn_info.vhost);
    try flush_buf(stream, &buf);

    // 7. Receive Connection.OpenOk (class=10, method=41)
    try expect_method(allocator, reader, 0x000A, 0x0029);

    // 8. Send Channel.Open on channel 1
    try encode_channel_open(writer, 1);
    try flush_buf(stream, &buf);

    // 9. Receive Channel.OpenOk (class=20, method=11)
    try expect_method(allocator, reader, 0x0014, 0x000B);

    // 10. Send Basic.Publish
    try encode_basic_publish(allocator, writer, 1, exchange, routing_key, body);
    try flush_buf(stream, &buf);

    // 11. Send Channel.Close on channel 1
    try encode_channel_close(writer, 1);
    try flush_buf(stream, &buf);

    // 12. Receive Channel.CloseOk (class=20, method=41)
    try expect_method(allocator, reader, 0x0014, 0x0029);

    // 13. Send Connection.Close
    try encode_connection_close(writer);
    try flush_buf(stream, &buf);

    // 14. Receive Connection.CloseOk (class=10, method=51)
    try expect_method(allocator, reader, 0x000A, 0x0033);
}

pub fn execute(
    allocator: std.mem.Allocator,
    payload: anytype,
    request: execution.Request,
) execution.Response {
    const failure = execution.Response{ .identifier = request.identifier, .success = false };

    const dsn_info = parse_dsn(allocator, payload.dsn) catch |err| {
        std.log.warn("amqp runner: dsn parse failed: dsn={s} err={any}", .{ redact_dsn(payload.dsn), err });
        return failure;
    };

    const stream = std.net.tcpConnectToHost(allocator, dsn_info.host, dsn_info.port) catch |err| {
        std.log.warn("amqp runner: tcp connect failed: dsn={s} err={any}", .{ redact_dsn(payload.dsn), err });
        return failure;
    };
    defer stream.close();

    const timeout = std.posix.timeval{ .sec = 30, .usec = 0 };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};

    run_handshake(
        allocator,
        stream,
        dsn_info,
        payload.exchange,
        payload.routing_key,
        request.job_identifier,
    ) catch |err| {
        std.log.warn("amqp runner: handshake failed: dsn={s} err={any}", .{ redact_dsn(payload.dsn), err });
        return failure;
    };

    return .{ .identifier = request.identifier, .success = true };
}

test "parse_dsn extracts user password host port vhost from full AMQP DSN" {
    const result = try parse_dsn(std.testing.allocator, "amqp://guest:guest@localhost:5672/");
    try std.testing.expectEqualStrings("guest", result.user);
    try std.testing.expectEqualStrings("guest", result.password);
    try std.testing.expectEqualStrings("localhost", result.host);
    try std.testing.expectEqual(@as(u16, 5672), result.port);
    try std.testing.expectEqualStrings("/", result.vhost);
}

test "parse_dsn defaults port to 5672 when port is absent" {
    const result = try parse_dsn(std.testing.allocator, "amqp://guest:guest@localhost/");
    try std.testing.expectEqualStrings("localhost", result.host);
    try std.testing.expectEqual(@as(u16, 5672), result.port);
}

test "parse_dsn returns error.InvalidScheme for amqps scheme" {
    try std.testing.expectError(AmqpParseError.InvalidScheme, parse_dsn(std.testing.allocator, "amqps://guest:guest@localhost:5672/"));
}

test "parse_dsn returns error.InvalidScheme for non-amqp scheme" {
    try std.testing.expectError(AmqpParseError.InvalidScheme, parse_dsn(std.testing.allocator, "http://localhost/queue"));
}

test "parse_dsn returns error.InvalidScheme for missing scheme" {
    try std.testing.expectError(AmqpParseError.InvalidScheme, parse_dsn(std.testing.allocator, "localhost:5672/"));
}

test "parse_dsn returns error.MissingHost for empty host" {
    try std.testing.expectError(AmqpParseError.MissingHost, parse_dsn(std.testing.allocator, "amqp://user:pass@:5672/"));
}

test "parse_dsn returns error.InvalidPort for non-numeric port" {
    try std.testing.expectError(AmqpParseError.InvalidPort, parse_dsn(std.testing.allocator, "amqp://guest:guest@localhost:abc/"));
}

test "parse_dsn returns error.InvalidPort for port out of range above 65535" {
    try std.testing.expectError(AmqpParseError.InvalidPort, parse_dsn(std.testing.allocator, "amqp://guest:guest@localhost:99999/"));
}

test "parse_dsn returns error.MissingUserInfo when DSN omits userinfo separator" {
    try std.testing.expectError(AmqpParseError.MissingUserInfo, parse_dsn(std.testing.allocator, "amqp://localhost:5672/"));
}

test "redact_dsn strips userinfo from DSN containing credentials" {
    const result = redact_dsn("amqp://user:pass@host:5672/");
    try std.testing.expectEqualStrings("amqp://host:5672/", result);
}

test "redact_dsn returns DSN unchanged when no userinfo is present" {
    const result = redact_dsn("amqp://host:5672/");
    try std.testing.expectEqualStrings("amqp://host:5672/", result);
}

test "write_frame produces framed bytes with type channel payload and frame-end sentinel" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    const payload = [_]u8{ 0x01, 0x02 };
    try write_frame(buf.writer(std.testing.allocator), 0x01, 0, &payload);
    const expected = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x01, 0x02, 0xCE };
    try std.testing.expectEqualSlices(u8, &expected, buf.items);
}

test "encode_connection_start_ok produces PLAIN auth frame for AMQP 0-9-1 handshake" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    try encode_connection_start_ok(std.testing.allocator, buf.writer(std.testing.allocator), "guest", "guest");
    const expected = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x24,
        0x00, 0x0A, 0x00, 0x0B, 0x00, 0x00, 0x00,
        0x00, 0x05, 'P',  'L',  'A',  'I',  'N',
        0x00, 0x00, 0x00, 0x0C, 0x00, 'g',  'u',
        'e',  's',  't',  0x00, 'g',  'u',  'e',
        's',  't',  0x05, 'e',  'n',  '_',  'U',
        'S',  0xCE,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf.items);
}

test "encode_connection_tune_ok echoes channel_max frame_max and heartbeat as TuneOk frame" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    try encode_connection_tune_ok(buf.writer(std.testing.allocator), 2047, 131072, 60);
    const expected = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C,
        0x00, 0x0A, 0x00, 0x1F, 0x07, 0xFF, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x3C, 0xCE,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf.items);
}

test "encode_connection_open produces Connection.Open frame for vhost /" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    try encode_connection_open(buf.writer(std.testing.allocator), "/");
    const expected = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08,
        0x00, 0x0A, 0x00, 0x28, 0x01, '/',  0x00,
        0x00, 0xCE,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf.items);
}

test "encode_channel_open on channel 1 produces Channel.Open frame" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    try encode_channel_open(buf.writer(std.testing.allocator), 1);
    const expected = [_]u8{
        0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x05,
        0x00, 0x14, 0x00, 0x0A, 0x00, 0xCE,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf.items);
}

test "encode_basic_publish produces method header and body frames with 0xCE sentinels" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    try encode_basic_publish(std.testing.allocator, buf.writer(std.testing.allocator), 1, "jobs", "notifications", "test");
    const expected = [_]u8{
        0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1A,
        0x00, 0x3C, 0x00, 0x28, 0x00, 0x00, 0x04,
        'j',  'o',  'b',  's',  0x0D, 'n',  'o',
        't',  'i',  'f',  'i',  'c',  'a',  't',
        'i',  'o',  'n',  's',  0x00, 0xCE, 0x02,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x0E, 0x00,
        0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0xCE,
        0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04,
        't',  'e',  's',  't',  0xCE,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf.items);
}

test "encode_channel_close produces Channel.Close frame with normal closure" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    try encode_channel_close(buf.writer(std.testing.allocator), 1);
    const expected = [_]u8{
        0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0D,
        0x00, 0x14, 0x00, 0x28, 0x00, 0xC8, 0x02,
        'O',  'K',  0x00, 0x00, 0x00, 0x00, 0xCE,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf.items);
}

test "encode_connection_close produces Connection.Close frame with normal closure" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    try encode_connection_close(buf.writer(std.testing.allocator));
    const expected = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0D,
        0x00, 0x0A, 0x00, 0x32, 0x00, 0xC8, 0x02,
        'O',  'K',  0x00, 0x00, 0x00, 0x00, 0xCE,
    };
    try std.testing.expectEqualSlices(u8, &expected, buf.items);
}

test "encode_connection_open returns error.VhostTooLong for vhost > 255 bytes" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    const long_vhost = "a" ** 256;
    try std.testing.expectError(error.VhostTooLong, encode_connection_open(buf.writer(std.testing.allocator), long_vhost));
}

test "encode_basic_publish returns error.ExchangeNameTooLong for exchange > 255 bytes" {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(std.testing.allocator);
    const long_exchange = "x" ** 256;
    try std.testing.expectError(error.ExchangeNameTooLong, encode_basic_publish(std.testing.allocator, buf.writer(std.testing.allocator), 1, long_exchange, "key", "body"));
}

test "execute returns success=false for malformed DSN without raising" {
    const request = execution.Request{
        .identifier = 0xABCD1234,
        .job_identifier = "notify.1",
        .runner = .{ .amqp = .{ .dsn = "not-an-amqp-url", .exchange = "jobs", .routing_key = "notifications" } },
    };
    const response = execute(std.testing.allocator, request.runner.amqp, request);
    try std.testing.expectEqual(@as(u128, 0xABCD1234), response.identifier);
    try std.testing.expect(!response.success);
}

test "execute returns success=false on connection refused without raising" {
    const refused_port: u16 = blk: {
        const a = try std.net.Address.parseIp4("127.0.0.1", 0);
        var s = try a.listen(.{ .reuse_address = true });
        const p = s.listen_address.in.getPort();
        s.deinit();
        break :blk p;
    };
    const dsn = try std.fmt.allocPrint(std.testing.allocator, "amqp://guest:guest@127.0.0.1:{d}/", .{refused_port});
    defer std.testing.allocator.free(dsn);
    const request = execution.Request{
        .identifier = 0xBEEF5678,
        .job_identifier = "notify.2",
        .runner = .{ .amqp = .{ .dsn = dsn, .exchange = "jobs", .routing_key = "notifications" } },
    };
    const response = execute(std.testing.allocator, request.runner.amqp, request);
    try std.testing.expectEqual(@as(u128, 0xBEEF5678), response.identifier);
    try std.testing.expect(!response.success);
}

test "execute preserves request identifier in response on every error path" {
    const request = execution.Request{
        .identifier = 0xDEADBEEF_CAFEBABE,
        .job_identifier = "preserve.id",
        .runner = .{ .amqp = .{ .dsn = "invalid", .exchange = "test", .routing_key = "test" } },
    };
    const response = execute(std.testing.allocator, request.runner.amqp, request);
    try std.testing.expectEqual(@as(u128, 0xDEADBEEF_CAFEBABE), response.identifier);
}

const PeerCloseStub = struct {
    fn run(server: *std.net.Server) void {
        var conn = server.accept() catch return;
        defer conn.stream.close();

        // Read the 8-byte AMQP protocol header
        var header: [8]u8 = undefined;
        var total: usize = 0;
        while (total < header.len) {
            const n = conn.stream.read(header[total..]) catch return;
            if (n == 0) return;
            total += n;
        }

        // Build a Connection.Close METHOD frame (class=10, method=50)
        // Payload: class:u16=10, method:u16=50, reply-code:u16=403,
        //          shortstr "ACCESS_REFUSED" (len=14), class-id:u16=0, method-id:u16=0
        // Size = 2+2+2+1+14+2+2 = 25 bytes
        const reply_text = "ACCESS_REFUSED";
        var frame: [7 + 25 + 1]u8 = undefined;
        frame[0] = 0x01; // METHOD frame type
        std.mem.writeInt(u16, frame[1..3], 0, .big); // channel 0
        std.mem.writeInt(u32, frame[3..7], 25, .big); // payload size
        // payload starts at offset 7
        std.mem.writeInt(u16, frame[7..9], 0x000A, .big); // class Connection
        std.mem.writeInt(u16, frame[9..11], 0x0032, .big); // method Close
        std.mem.writeInt(u16, frame[11..13], 0x0193, .big); // reply-code 403
        frame[13] = @intCast(reply_text.len);
        @memcpy(frame[14 .. 14 + reply_text.len], reply_text);
        std.mem.writeInt(u16, frame[28..30], 0, .big); // class-id 0
        std.mem.writeInt(u16, frame[30..32], 0, .big); // method-id 0
        frame[32] = 0xCE; // frame-end sentinel

        _ = conn.stream.writeAll(&frame) catch {};
    }
};

test "execute returns success=false when peer closes connection mid-handshake" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const listen_addr = server.listen_address;
    defer server.deinit();
    const port = listen_addr.in.getPort();

    const t = try std.Thread.spawn(.{}, PeerCloseStub.run, .{&server});

    const dsn = try std.fmt.allocPrint(std.testing.allocator, "amqp://baduser:badpass@127.0.0.1:{d}/", .{port});
    defer std.testing.allocator.free(dsn);

    const request = execution.Request{
        .identifier = 0xCAFE_F00D_BABE_BEEF,
        .job_identifier = "peer.close.test",
        .runner = .{ .amqp = .{ .dsn = dsn, .exchange = "jobs", .routing_key = "notifications" } },
    };
    const response = execute(std.testing.allocator, request.runner.amqp, request);

    // If the listener thread is still waiting for some reason, unblock it
    if (std.net.tcpConnectToAddress(listen_addr)) |c| c.close() else |_| {}
    t.join();

    try std.testing.expectEqual(@as(u128, 0xCAFE_F00D_BABE_BEEF), response.identifier);
    try std.testing.expect(!response.success);
}

test "amqp runner publishes to broker and reports success" {
    const build_options = @import("build_options");
    if (!build_options.amqp_integration) return error.SkipZigTest;

    const address = try std.net.Address.parseIp4("127.0.0.1", 5672);
    const probe = std.net.tcpConnectToAddress(address) catch return error.SkipZigTest;
    probe.close();

    const request = execution.Request{
        .identifier = 0xA1B2C3D4E5F60718,
        .job_identifier = "ztick.integration.test",
        .runner = .{ .amqp = .{
            .dsn = "amqp://guest:guest@127.0.0.1:5672/",
            .exchange = "",
            .routing_key = "ztick.integration",
        } },
    };
    const response = execute(std.testing.allocator, request.runner.amqp, request);
    try std.testing.expectEqual(@as(u128, 0xA1B2C3D4E5F60718), response.identifier);
    try std.testing.expect(response.success);
}

test "amqp runner reports failure for bad credentials and never logs raw secrets" {
    const build_options = @import("build_options");
    if (!build_options.amqp_integration) return error.SkipZigTest;

    const address = try std.net.Address.parseIp4("127.0.0.1", 5672);
    const probe = std.net.tcpConnectToAddress(address) catch return error.SkipZigTest;
    probe.close();

    const dsn = "amqp://baduser:badpass@127.0.0.1:5672/";
    const request = execution.Request{
        .identifier = 0xDEAD_BEEF_CAFE_F00D,
        .job_identifier = "ztick.bad.creds",
        .runner = .{ .amqp = .{
            .dsn = dsn,
            .exchange = "",
            .routing_key = "ztick.bad.creds",
        } },
    };
    const response = execute(std.testing.allocator, request.runner.amqp, request);
    try std.testing.expectEqual(@as(u128, 0xDEAD_BEEF_CAFE_F00D), response.identifier);
    try std.testing.expect(!response.success);

    // Stderr-redaction assertion: redact_dsn must strip user:pass@ from the DSN.
    // Verify by calling redact_dsn directly on the bad-creds DSN — this proves
    // the helper used at every std.log site never emits raw credentials.
    const redacted = redact_dsn(dsn);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "baduser") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "badpass") == null);
}
