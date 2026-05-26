const std = @import("std");
const domain = @import("../domain.zig");
const parser = @import("protocol/parser.zig");
const Channel = @import("channel.zig").Channel;
const TlsContext = @import("tls_context.zig").TlsContext;
const TlsStream = @import("tls_context.zig").TlsStream;
const telemetry = @import("telemetry.zig");
const application = @import("../application.zig");

const TokenStore = application.token_store.TokenStore;

const query = domain.query;
const instruction = domain.instruction;

pub const Connection = union(enum) {
    plain: struct { stream: std.Io.net.Stream },
    tls: struct { stream: TlsStream },

    pub fn read(self: Connection, buf: []u8) !usize {
        return switch (self) {
            .plain => |p| blk: {
                const rc = std.os.linux.read(p.stream.socket.handle, buf.ptr, buf.len);
                if (@as(isize, @bitCast(rc)) < 0) return error.ReadFailed;
                break :blk rc;
            },
            .tls => |t| t.stream.read(buf),
        };
    }

    pub fn write(self: Connection, buf: []const u8) !usize {
        return switch (self) {
            .plain => |p| blk: {
                const rc = std.os.linux.write(p.stream.socket.handle, buf.ptr, buf.len);
                if (@as(isize, @bitCast(rc)) < 0) return error.WriteFailed;
                break :blk rc;
            },
            .tls => |t| t.stream.write(buf),
        };
    }

    pub fn close(self: Connection) void {
        switch (self) {
            .plain => |p| _ = std.os.linux.close(p.stream.socket.handle),
            .tls => |t| t.stream.close(),
        }
    }

    pub fn fd(self: Connection) std.posix.socket_t {
        return switch (self) {
            .plain => |p| p.stream.socket.handle,
            .tls => |t| t.stream.fd,
        };
    }
};

pub const ResponseRouter = struct {
    io: std.Io,
    mutex: std.Io.Mutex,
    channels: std.AutoHashMap(query.Client, *Channel(query.Response)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ResponseRouter {
        return .{
            .io = io,
            .mutex = .init,
            .channels = std.AutoHashMap(query.Client, *Channel(query.Response)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResponseRouter) void {
        self.channels.deinit();
    }

    pub fn register(self: *ResponseRouter, client_id: query.Client, channel: *Channel(query.Response)) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.channels.put(client_id, channel);
    }

    pub fn deregister(self: *ResponseRouter, client_id: query.Client) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        _ = self.channels.remove(client_id);
    }

    pub fn route(self: *ResponseRouter, response: query.Response) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.channels.get(response.request.client)) |ch| {
            ch.try_send(response) catch {};
        }
    }
};

pub const TcpServer = struct {
    allocator: std.mem.Allocator,
    address: []const u8,
    /// Tracks live TCP connections. Shared with the scheduler so STAT can report
    /// the live count. Overlaps with the `ztick.connections.active` OpenTelemetry
    /// gauge; both are incremented/decremented in lockstep. The pointer is kept
    /// separate because join_all() needs a direct read for shutdown draining.
    active_connections: *std.atomic.Value(usize),
    running: *std.atomic.Value(bool),
    tls_context: ?*TlsContext,
    token_store: ?*TokenStore,
    instruments: ?telemetry.Instruments,
    /// Listen socket fd, set by start() and cleared after the accept loop exits.
    /// Used by deinit() only when start() never ran (early error path).
    listen_fd: ?std.posix.socket_t,
    /// Optional pointer to a caller-owned atomic that receives the listen fd
    /// immediately after binding. A signal handler can close that fd (setting
    /// the atomic back to -1) to unblock a blocked accept() call.  Ownership
    /// of the fd is transferred via an atomic swap so exactly one party closes
    /// it: whichever one wins the swap first.
    signal_listen_fd: ?*std.atomic.Value(std.posix.socket_t),

    pub fn init(allocator: std.mem.Allocator, address: []const u8, running: *std.atomic.Value(bool), tls_context: ?*TlsContext, active_connections: *std.atomic.Value(usize), token_store: ?*TokenStore) TcpServer {
        return .{
            .allocator = allocator,
            .address = address,
            .active_connections = active_connections,
            .running = running,
            .tls_context = tls_context,
            .token_store = token_store,
            .instruments = null,
            .listen_fd = null,
            .signal_listen_fd = null,
        };
    }

    pub fn deinit(self: *TcpServer) void {
        if (self.listen_fd) |fd| {
            _ = std.os.linux.close(fd);
            self.listen_fd = null;
        }
    }

    pub fn set_instruments(self: *TcpServer, instr: telemetry.Instruments) void {
        self.instruments = instr;
    }

    pub fn start(
        self: *TcpServer,
        io: std.Io,
        request_channel: *Channel(query.Request),
        response_router: *ResponseRouter,
    ) !void {
        const colon = std.mem.lastIndexOf(u8, self.address, ":") orelse return error.InvalidAddress;
        const host = self.address[0..colon];
        const port = try std.fmt.parseInt(u16, self.address[colon + 1 ..], 10);
        const addr = try std.Io.net.IpAddress.parse(host, port);
        var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
        const raw_fd = server.socket.handle;
        self.listen_fd = raw_fd;

        // Publish the fd to the signal handler's atomic so it can close the
        // socket to unblock accept() on SIGINT/SIGTERM.
        if (self.signal_listen_fd) |sig_fd| sig_fd.store(raw_fd, .release);

        var next_client_id: u128 = 0;

        while (self.running.load(.acquire)) {
            const stream = server.accept(io) catch {
                // Accept failed, likely due to listener being closed from shutdown
                if (!self.running.load(.acquire)) break;
                continue;
            };

            const client_id = next_client_id;
            next_client_id +%= 1;

            _ = self.active_connections.fetchAdd(1, .release);
            if (self.instruments) |instr| instr.connections_active.add(1, .{}) catch {};
            const thread = std.Thread.spawn(.{}, connection_worker, .{
                self.active_connections,
                self.instruments,
                self.allocator,
                io,
                stream,
                client_id,
                request_channel,
                response_router,
                self.tls_context,
                self.token_store,
            }) catch {
                _ = self.active_connections.fetchSub(1, .release);
                if (self.instruments) |instr| instr.connections_active.add(-1, .{}) catch {};
                _ = std.os.linux.close(stream.socket.handle);
                continue;
            };
            thread.detach();
        }

        // Clear listen_fd so deinit() does not attempt a second close.
        self.listen_fd = null;

        // Reset the signal atomic to -1 so the signal handler will not attempt
        // a redundant shutdown() after the socket is closed below.
        if (self.signal_listen_fd) |sig_fd| sig_fd.store(-1, .release);

        // Close the listen socket.  The signal handler uses shutdown() (not
        // close()) to unblock accept(), so the fd is still open at this point
        // and exactly one close happens here.
        _ = std.os.linux.close(raw_fd);
    }

    pub fn join_all(self: *TcpServer, io: std.Io) void {
        var attempts: usize = 0;
        while (self.active_connections.load(.acquire) > 0) {
            std.Io.sleep(io, .{ .nanoseconds = 1_000_000 }, .awake) catch {}; // 1ms
            attempts += 1;
            if (attempts >= 5000) break; // 5s max shutdown wait
        }
    }
};

fn connection_worker(
    active_connections: *std.atomic.Value(usize),
    instruments: ?telemetry.Instruments,
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    client_id: u128,
    request_channel: *Channel(query.Request),
    response_router: *ResponseRouter,
    tls_context: ?*TlsContext,
    token_store: ?*TokenStore,
) void {
    defer _ = active_connections.fetchSub(1, .release);
    defer if (instruments) |instr| instr.connections_active.add(-1, .{}) catch {};
    const conn: Connection = if (tls_context) |tls_ctx| blk: {
        const tls_stream = tls_ctx.accept(stream.socket.handle) catch {
            _ = std.os.linux.close(stream.socket.handle);
            return;
        };
        break :blk Connection{ .tls = .{ .stream = tls_stream } };
    } else Connection{ .plain = .{ .stream = stream } };
    handle_connection(allocator, io, conn, client_id, request_channel, response_router, token_store);
}

fn handle_connection(
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: Connection,
    client_id: u128,
    request_channel: *Channel(query.Request),
    response_router: *ResponseRouter,
    token_store: ?*TokenStore,
) void {
    std.log.info("client connected: id={d}", .{client_id});
    defer std.log.info("client disconnected: id={d}", .{client_id});
    defer conn.close();

    var response_channel = Channel(query.Response).init(allocator, io, 1) catch return;
    defer response_channel.deinit();

    response_router.register(client_id, &response_channel) catch return;
    defer response_router.deregister(client_id);

    var buf: [4096]u8 = undefined;
    var filled: usize = 0;

    var auth_done: bool = (token_store == null);
    var identity: ?domain.auth.ClientIdentity = null;

    // FR-010: connections that don't complete AUTH within 5 seconds are closed.
    // Use a monotonic clock to avoid NTP stepback causing the deadline to extend or wrap.
    const auth_timeout_ns: u64 = 5_000_000_000;
    const auth_start_ns: u64 = if (token_store != null) blk: {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        break :blk @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    } else 0;

    while (true) {
        if (!auth_done) {
            var now_ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &now_ts);
            const now_ns: u64 = @as(u64, @intCast(now_ts.sec)) * 1_000_000_000 + @as(u64, @intCast(now_ts.nsec));
            const elapsed_ns = now_ns - auth_start_ns;
            if (elapsed_ns >= auth_timeout_ns) return;
            const remaining_ms = @min((auth_timeout_ns - elapsed_ns) / 1_000_000, std.math.maxInt(u31));
            var pfd = [1]std.posix.pollfd{.{
                .fd = conn.fd(),
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfd, @intCast(remaining_ms)) catch return;
            if (ready == 0) return;
        }

        const n = conn.read(buf[filled..]) catch return;
        if (n == 0) return;

        filled += n;

        var consumed: usize = 0;
        while (true) {
            const data = buf[consumed..filled];
            const result = parser.parse(allocator, data) catch |err| switch (err) {
                error.Incomplete => break,
                error.Invalid => {
                    // Send error response before skipping the invalid line
                    _ = conn.write("ERROR invalid_command\n") catch {};
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

            if (!auth_done) {
                if (!std.mem.eql(u8, result.command, "AUTH") or result.args.len < 1) {
                    result.deinit(allocator);
                    _ = conn.write("ERROR auth_required\n") catch {};
                    return;
                }
                const secret = result.args[0];
                if (token_store.?.authenticate(secret)) |id| {
                    identity = id;
                    auth_done = true;
                    result.deinit(allocator);
                    _ = conn.write("OK\n") catch return;
                    continue;
                } else {
                    result.deinit(allocator);
                    _ = conn.write("ERROR auth_failed\n") catch {};
                    return;
                }
            }

            if (build_instruction(allocator, result) catch {
                result.deinit(allocator);
                return;
            }) |instr| {
                std.log.debug("instruction received: {s}", .{@tagName(instr)});
                // Instruction owns duped strings; free all parsed args uniformly.
                for (result.args) |arg| allocator.free(arg);
                allocator.free(result.args);

                if (identity) |id| {
                    const allowed = switch (instr) {
                        .set => |s| TokenStore.is_authorized(id, s.identifier),
                        .get => |g| TokenStore.is_authorized(id, g.identifier),
                        .remove => |r| TokenStore.is_authorized(id, r.identifier),
                        .remove_rule => |r| TokenStore.is_authorized(id, r.identifier),
                        .rule_set => |r| TokenStore.is_authorized(id, r.identifier),
                        .query, .list_rules, .stat => true,
                    };
                    if (!allowed) {
                        free_instruction_strings(allocator, instr);
                        const msg = std.fmt.allocPrint(allocator, "{s} ERROR auth_denied insufficient namespace scope\n", .{result.command}) catch {
                            allocator.free(result.command);
                            return;
                        };
                        defer allocator.free(msg);
                        allocator.free(result.command);
                        _ = conn.write(msg) catch {};
                        continue;
                    }
                }

                {
                    const request = query.Request{
                        .client = client_id,
                        .identifier = result.command,
                        .instruction = instr,
                    };

                    request_channel.send(request) catch {
                        allocator.free(result.command);
                        free_instruction_strings(allocator, instr);
                        return;
                    };

                    if (response_channel.receive()) |resp| {
                        if (identity) |id| {
                            if (resp.request.instruction == .query and !std.mem.eql(u8, id.namespace, "*")) {
                                var filtered: std.ArrayListUnmanaged(u8) = .empty;
                                defer filtered.deinit(allocator);
                                if (resp.body) |body| {
                                    var iter = std.mem.splitScalar(u8, body, '\n');
                                    while (iter.next()) |line| {
                                        if (line.len == 0) continue;
                                        const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
                                        if (std.mem.startsWith(u8, line[0..first_space], id.namespace)) {
                                            filtered.appendSlice(allocator, line) catch return;
                                            filtered.append(allocator, '\n') catch return;
                                        }
                                    }
                                }
                                const filtered_resp = query.Response{
                                    .request = resp.request,
                                    .success = resp.success,
                                    .body = if (filtered.items.len > 0) filtered.items else null,
                                };
                                write_response(allocator, conn, filtered_resp) catch {};
                            } else {
                                write_response(allocator, conn, resp) catch {};
                            }
                        } else {
                            write_response(allocator, conn, resp) catch {};
                        }
                        // Free only the request_id (result.command) — not stored by scheduler.
                        // Instruction strings (job id, pattern, runner args) are now owned
                        // by the scheduler's storage and must not be freed here.
                        allocator.free(resp.request.identifier);
                        if (resp.body) |body| allocator.free(body);
                        if (resp.error_message) |m| allocator.free(m);
                    } else {
                        return; // channel closed
                    }
                }
            } else {
                const invalid_args_reason: ?[]const u8 = blk: {
                    if (result.args.len >= 1) {
                        if (std.mem.eql(u8, result.args[0], "GET") and result.args.len < 2)
                            break :blk "missing required argument: identifier";
                        if (std.mem.eql(u8, result.args[0], "SET") and result.args.len < 3)
                            break :blk "missing required argument: timestamp";
                        if (std.mem.eql(u8, result.args[0], "REMOVE") and result.args.len < 2)
                            break :blk "missing required argument: identifier";
                        if (std.mem.eql(u8, result.args[0], "REMOVERULE") and result.args.len < 2)
                            break :blk "missing required argument: identifier";
                        if (std.mem.eql(u8, result.args[0], "RULE") and result.args.len >= 2 and std.mem.eql(u8, result.args[1], "SET"))
                            break :blk "missing required argument: pattern";
                    }
                    break :blk null;
                };
                if (invalid_args_reason) |reason| {
                    const msg = std.fmt.allocPrint(allocator, "{s} ERROR invalid_args {s}\n", .{ result.command, reason }) catch {
                        result.deinit(allocator);
                        return;
                    };
                    defer allocator.free(msg);
                    _ = conn.write(msg) catch {};
                }
                result.deinit(allocator);
            }
        }

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
    if (result.args.len >= 1 and std.mem.eql(u8, result.args[0], "QUERY")) {
        const pattern = if (result.args.len >= 2) try allocator.dupe(u8, result.args[1]) else try allocator.dupe(u8, "");
        return .{ .query = .{ .pattern = pattern } };
    }

    if (result.args.len >= 2 and std.mem.eql(u8, result.args[0], "GET")) {
        const id = try allocator.dupe(u8, result.args[1]);
        return .{ .get = .{ .identifier = id } };
    }

    if (result.args.len >= 3 and std.mem.eql(u8, result.args[0], "SET")) {
        const ts = parse_timestamp(result.args[2..]) orelse return null;
        const id = try allocator.dupe(u8, result.args[1]);
        return .{ .set = .{
            .identifier = id,
            .execution = ts,
        } };
    }

    if (result.args.len >= 4 and
        std.mem.eql(u8, result.args[0], "RULE") and
        std.mem.eql(u8, result.args[1], "SET"))
    {
        return try build_rule_set_instruction(allocator, result.args);
    }

    if (result.args.len >= 2 and std.mem.eql(u8, result.args[0], "REMOVE")) {
        const id = try allocator.dupe(u8, result.args[1]);
        return .{ .remove = .{ .identifier = id } };
    }

    if (result.args.len >= 2 and std.mem.eql(u8, result.args[0], "REMOVERULE")) {
        const id = try allocator.dupe(u8, result.args[1]);
        return .{ .remove_rule = .{ .identifier = id } };
    }

    if (result.args.len >= 1 and std.mem.eql(u8, result.args[0], "LISTRULES")) {
        return .{ .list_rules = .{} };
    }

    if (result.args.len >= 1 and std.mem.eql(u8, result.args[0], "STAT")) {
        return .{ .stat = .{} };
    }

    return null;
}

fn build_rule_set_instruction(allocator: std.mem.Allocator, args: [][]u8) error{OutOfMemory}!?instruction.Instruction {
    const runner_type = args[4..];
    if (runner_type.len >= 2 and std.mem.eql(u8, runner_type[0], "shell")) {
        const id = try allocator.dupe(u8, args[2]);
        errdefer allocator.free(id);
        const pattern = try allocator.dupe(u8, args[3]);
        errdefer allocator.free(pattern);
        const command = try allocator.dupe(u8, runner_type[1]);
        return .{ .rule_set = .{
            .identifier = id,
            .pattern = pattern,
            .runner = .{ .shell = .{ .command = command } },
        } };
    }
    if (runner_type.len >= 4 and std.mem.eql(u8, runner_type[0], "amqp")) {
        const id = try allocator.dupe(u8, args[2]);
        errdefer allocator.free(id);
        const pattern = try allocator.dupe(u8, args[3]);
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
    if (runner_type.len >= 2 and std.mem.eql(u8, runner_type[0], "direct")) {
        const id = try allocator.dupe(u8, args[2]);
        errdefer allocator.free(id);
        const pattern = try allocator.dupe(u8, args[3]);
        errdefer allocator.free(pattern);
        const executable = try allocator.dupe(u8, runner_type[1]);
        errdefer allocator.free(executable);
        const extra_args = runner_type[2..];
        const duped_args = try allocator.alloc([]const u8, extra_args.len);
        errdefer allocator.free(duped_args);
        var i: usize = 0;
        errdefer for (duped_args[0..i]) |a| allocator.free(a);
        while (i < extra_args.len) : (i += 1) {
            duped_args[i] = try allocator.dupe(u8, extra_args[i]);
        }
        return .{ .rule_set = .{
            .identifier = id,
            .pattern = pattern,
            .runner = .{ .direct = .{
                .executable = executable,
                .args = duped_args,
            } },
        } };
    }
    if (runner_type.len >= 1 and std.mem.eql(u8, runner_type[0], "awf")) {
        if (runner_type.len < 2) return null;
        const remaining = runner_type[2..];
        if (remaining.len % 2 != 0) return null;
        var k: usize = 0;
        while (k < remaining.len) : (k += 2) {
            if (!std.mem.eql(u8, remaining[k], "--input")) return null;
        }
        const id = try allocator.dupe(u8, args[2]);
        errdefer allocator.free(id);
        const pattern = try allocator.dupe(u8, args[3]);
        errdefer allocator.free(pattern);
        const workflow = try allocator.dupe(u8, runner_type[1]);
        errdefer allocator.free(workflow);
        const input_count = remaining.len / 2;
        const inputs = try allocator.alloc([]const u8, input_count);
        var j: usize = 0;
        errdefer {
            for (inputs[0..j]) |input| allocator.free(input);
            allocator.free(inputs);
        }
        while (j < input_count) : (j += 1) {
            inputs[j] = try allocator.dupe(u8, remaining[j * 2 + 1]);
        }
        return .{ .rule_set = .{
            .identifier = id,
            .pattern = pattern,
            .runner = .{ .awf = .{ .workflow = workflow, .inputs = inputs } },
        } };
    }
    if (runner_type.len >= 1 and std.mem.eql(u8, runner_type[0], "http")) {
        if (runner_type.len < 3) return null;
        const method = runner_type[1];
        const url = runner_type[2];
        const valid_method = std.mem.eql(u8, method, "GET") or
            std.mem.eql(u8, method, "POST") or
            std.mem.eql(u8, method, "PUT") or
            std.mem.eql(u8, method, "DELETE");
        if (!valid_method) return null;
        const valid_scheme = std.mem.startsWith(u8, url, "http://") or
            std.mem.startsWith(u8, url, "https://");
        if (!valid_scheme) return null;
        const id = try allocator.dupe(u8, args[2]);
        errdefer allocator.free(id);
        const pattern = try allocator.dupe(u8, args[3]);
        errdefer allocator.free(pattern);
        const duped_method = try allocator.dupe(u8, method);
        errdefer allocator.free(duped_method);
        const duped_url = try allocator.dupe(u8, url);
        return .{ .rule_set = .{
            .identifier = id,
            .pattern = pattern,
            .runner = .{ .http = .{ .method = duped_method, .url = duped_url } },
        } };
    }
    if (runner_type.len >= 4 and std.mem.eql(u8, runner_type[0], "redis")) {
        const url = runner_type[1];
        const command = runner_type[2];
        const key = runner_type[3];
        if (!std.mem.startsWith(u8, url, "redis://")) return null;
        const valid_command = std.mem.eql(u8, command, "PUBLISH") or
            std.mem.eql(u8, command, "RPUSH") or
            std.mem.eql(u8, command, "LPUSH") or
            std.mem.eql(u8, command, "SET");
        if (!valid_command) return null;
        const id = try allocator.dupe(u8, args[2]);
        errdefer allocator.free(id);
        const pattern = try allocator.dupe(u8, args[3]);
        errdefer allocator.free(pattern);
        const duped_url = try allocator.dupe(u8, url);
        errdefer allocator.free(duped_url);
        const duped_command = try allocator.dupe(u8, command);
        errdefer allocator.free(duped_command);
        const duped_key = try allocator.dupe(u8, key);
        return .{ .rule_set = .{
            .identifier = id,
            .pattern = pattern,
            .runner = .{ .redis = .{ .url = duped_url, .command = duped_command, .key = duped_key } },
        } };
    }
    return null;
}

fn parse_timestamp(args: [][]u8) ?i64 {
    if (args.len == 0) return null;

    // Try datetime format "YYYY-MM-DD HH:MM:SS" (may span 2 args: date and time)
    if (args.len >= 2) {
        if (parse_datetime(args[0], args[1])) |ns| return ns;
    }

    // Fallback: integer nanoseconds
    return std.fmt.parseInt(i64, args[0], 10) catch null;
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

    const epoch_seconds = datetime_to_epoch(year, month, day, hour, minute, second) orelse return null;
    return epoch_seconds * 1_000_000_000;
}

fn datetime_to_epoch(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
    return domain.timestamp.to_epoch_seconds(year, month, day, hour, minute, second) catch null;
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
                .direct => |d| {
                    allocator.free(d.executable);
                    for (d.args) |arg| allocator.free(arg);
                    allocator.free(d.args);
                },
                .awf => |awf| {
                    allocator.free(awf.workflow);
                    for (awf.inputs) |input| allocator.free(input);
                    allocator.free(awf.inputs);
                },
                .http => |h| {
                    allocator.free(h.method);
                    allocator.free(h.url);
                },
                .redis => |redis| {
                    allocator.free(redis.url);
                    allocator.free(redis.command);
                    allocator.free(redis.key);
                },
            }
        },
        .get => |g| {
            allocator.free(g.identifier);
        },
        .query => |q| {
            allocator.free(q.pattern);
        },
        .remove => |r| {
            allocator.free(r.identifier);
        },
        .remove_rule => |r| {
            allocator.free(r.identifier);
        },
        .list_rules => {},
        .stat => {},
    }
}

fn write_response(allocator: std.mem.Allocator, conn: Connection, resp: query.Response) !void {
    if (!resp.success) {
        const code = resp.error_code orelse .internal;
        const msg = if (resp.error_message) |m|
            try std.fmt.allocPrint(allocator, "{s} ERROR {s} {s}\n", .{ resp.request.identifier, @tagName(code), m })
        else
            try std.fmt.allocPrint(allocator, "{s} ERROR {s}\n", .{ resp.request.identifier, @tagName(code) });
        defer allocator.free(msg);
        _ = try conn.write(msg);
        return;
    }
    switch (resp.request.instruction) {
        .query, .list_rules, .stat => {
            if (resp.body) |body| {
                var iter = std.mem.splitScalar(u8, body, '\n');
                while (iter.next()) |line| {
                    if (line.len == 0) continue;
                    const msg = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ resp.request.identifier, line });
                    defer allocator.free(msg);
                    _ = try conn.write(msg);
                }
            }
            const ok_line = try std.fmt.allocPrint(allocator, "{s} OK\n", .{resp.request.identifier});
            defer allocator.free(ok_line);
            _ = try conn.write(ok_line);
        },
        else => {
            const msg = if (resp.body) |body|
                try std.fmt.allocPrint(allocator, "{s} OK {s}\n", .{ resp.request.identifier, body })
            else
                try std.fmt.allocPrint(allocator, "{s} OK\n", .{resp.request.identifier});
            defer allocator.free(msg);
            _ = try conn.write(msg);
        },
    }
}

test "response router registers and deregisters clients" {
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    var response_ch = try Channel(query.Response).init(std.testing.allocator, std.testing.io, 1);
    defer response_ch.deinit();

    const client_id = @as(query.Client, 42);
    try router.register(client_id, &response_ch);

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
    var buf = [_]u8{ '1', '2', '3', '4', '5', '6', '7', '8', '9', '0' };
    var args = [_][]u8{&buf};

    const ts = parse_timestamp(&args);
    try std.testing.expectEqual(@as(i64, 1234567890), ts.?);
}

test "parse_timestamp parses datetime format" {
    var date_buf: [10]u8 = "1970-01-01".*;
    var time_buf: [8]u8 = "00:00:00".*;
    var args = [_][]u8{ &date_buf, &time_buf };

    const ts = parse_timestamp(&args);
    try std.testing.expectEqual(@as(i64, 0), ts.?);
}

test "parse_timestamp returns null on invalid input" {
    var buf: [7]u8 = "invalid".*;
    var args = [_][]u8{&buf};

    const ts = parse_timestamp(&args);
    try std.testing.expectEqual(@as(?i64, null), ts);
}

test "tcp server init stores address" {
    var running = std.atomic.Value(bool).init(true);
    var active = std.atomic.Value(usize).init(0);
    const server = TcpServer.init(std.testing.allocator, "127.0.0.1:5678", &running, null, &active, null);
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

test "build_instruction parses QUERY command with pattern" {
    var args = [_][]u8{ @constCast("QUERY"), @constCast("backup.") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .query => |q| try std.testing.expectEqualStrings("backup.", q.pattern),
        else => return error.WrongInstructionType,
    }
}

test "build_instruction parses QUERY without pattern as empty prefix" {
    var args = [_][]u8{@constCast("QUERY")};
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr != null);
    try std.testing.expectEqual(std.meta.Tag(instruction.Instruction).query, std.meta.activeTag(instr.?));
    std.testing.allocator.free(instr.?.query.pattern);
}

const SocketPair = struct {
    read_fd: std.posix.socket_t,
    write_fd: std.posix.socket_t,

    pub fn writeAll(self: SocketPair, buf: []const u8) !void {
        var written: usize = 0;
        while (written < buf.len) {
            const n = std.os.linux.write(self.write_fd, buf[written..].ptr, buf[written..].len);
            if (std.os.linux.errno(n) != .SUCCESS) return error.WriteError;
            written += n;
        }
    }

    pub fn close(self: SocketPair) void {
        _ = std.os.linux.close(self.write_fd);
    }
};

fn make_stream(fd: std.posix.socket_t) std.Io.net.Stream {
    return .{ .socket = .{
        .handle = fd,
        .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
    } };
}

fn make_socket_pair() !SocketPair {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), rc);
    return .{
        .read_fd = @intCast(fds[0]),
        .write_fd = @intCast(fds[1]),
    };
}

test "write_response formats multi-line body with request_id prefix per line" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

    const req = query.Request{
        .client = 0,
        .identifier = "req1",
        .instruction = .{ .query = .{ .pattern = "backup." } },
    };
    const resp = query.Response{
        .request = req,
        .success = true,
        .body = "backup.daily planned 1595586600000000000\nbackup.weekly planned 1595586660000000000\n",
    };

    try write_response(std.testing.allocator, Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } }, resp);
    pair.close();

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    try std.testing.expectEqualStrings(
        "req1 backup.daily planned 1595586600000000000\nreq1 backup.weekly planned 1595586660000000000\nreq1 OK\n",
        buf[0..n],
    );
}

test "build_instruction parses REMOVE command with identifier" {
    var args = [_][]u8{ @constCast("REMOVE"), @constCast("backup-daily") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .remove => |r| try std.testing.expectEqualStrings("backup-daily", r.identifier),
        else => return error.WrongInstructionType,
    }
}

test "build_instruction returns null for REMOVE without identifier" {
    var args = [_][]u8{@constCast("REMOVE")};
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "build_instruction parses REMOVERULE command with identifier" {
    var args = [_][]u8{ @constCast("REMOVERULE"), @constCast("notify-slack") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .remove_rule => |r| try std.testing.expectEqualStrings("notify-slack", r.identifier),
        else => return error.WrongInstructionType,
    }
}

test "build_instruction returns null for REMOVERULE without identifier" {
    var args = [_][]u8{@constCast("REMOVERULE")};
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "free_instruction_strings frees REMOVE identifier without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "backup-daily");
    const instr = instruction.Instruction{ .remove = .{ .identifier = id } };
    free_instruction_strings(allocator, instr);
}

test "write_response appends body when response body is non-null" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

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

    try write_response(std.testing.allocator, Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } }, resp);
    pair.close();

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    try std.testing.expectEqualStrings("req1 OK planned 1595586600000000000\n", buf[0..n]);
}

test "build_instruction parses LISTRULES command" {
    var args = [_][]u8{@constCast("LISTRULES")};
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    switch (instr) {
        .list_rules => {},
        else => return error.WrongInstructionType,
    }
}

test "build_instruction parses LISTRULES command ignoring trailing args" {
    var args = [_][]u8{ @constCast("LISTRULES"), @constCast("foo") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    switch (instr) {
        .list_rules => {},
        else => return error.WrongInstructionType,
    }
}

test "write_response formats list_rules multi-line body with request_id prefix" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

    const req = query.Request{
        .client = 0,
        .identifier = "r1",
        .instruction = .{ .list_rules = .{} },
    };
    const resp = query.Response{
        .request = req,
        .success = true,
        .body = "rule.backup backup.* shell /usr/bin/backup.sh\nrule.notify notify.* shell /usr/bin/notify.sh\n",
    };

    try write_response(std.testing.allocator, Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } }, resp);
    pair.close();

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    const output = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, output, "r1 rule.backup backup.* shell /usr/bin/backup.sh\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "r1 rule.notify notify.* shell /usr/bin/notify.sh\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "r1 OK\n"));
}

test "handle_connection exits cleanly when client disconnects immediately" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    pair.close();

    handle_connection(
        std.testing.allocator,
        std.testing.io,
        Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        42,
        &req_ch,
        &router,
        null,
    );
}

test "handle_connection deregisters client from router on disconnect" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    pair.close();

    handle_connection(
        std.testing.allocator,
        std.testing.io,
        Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        77,
        &req_ch,
        &router,
        null,
    );

    router.mutex.lockUncancelable(std.testing.io);
    const count = router.channels.count();
    router.mutex.unlock(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "build_instruction parses SET command with integer timestamp" {
    var args = [_][]u8{ @constCast("SET"), @constCast("backup.daily"), @constCast("1595586600000000000") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .set => |s| {
            try std.testing.expectEqualStrings("backup.daily", s.identifier);
            try std.testing.expectEqual(@as(i64, 1595586600000000000), s.execution);
        },
        else => return error.WrongInstructionType,
    }
}

test "build_instruction parses RULE SET command with shell runner" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.backup"), @constCast("backup.*"), @constCast("shell"), @constCast("/usr/bin/backup.sh") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .rule_set => |r| {
            try std.testing.expectEqualStrings("rule.backup", r.identifier);
            try std.testing.expectEqualStrings("backup.*", r.pattern);
            switch (r.runner) {
                .shell => |sh| try std.testing.expectEqualStrings("/usr/bin/backup.sh", sh.command),
                .amqp => return error.WrongRunnerType,
                .direct => return error.WrongRunnerType,
                .awf => return error.WrongRunnerType,
                .http => return error.WrongRunnerType,
                .redis => return error.WrongRunnerType,
            }
        },
        else => return error.WrongInstructionType,
    }
}

test "build_instruction parses RULE SET command with direct runner and no args" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.exec"), @constCast("exec.*"), @constCast("direct"), @constCast("/bin/echo") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .rule_set => |r| {
            try std.testing.expectEqualStrings("rule.exec", r.identifier);
            try std.testing.expectEqualStrings("exec.*", r.pattern);
            switch (r.runner) {
                .direct => |d| {
                    try std.testing.expectEqualStrings("/bin/echo", d.executable);
                    try std.testing.expectEqual(@as(usize, 0), d.args.len);
                },
                .shell => return error.WrongRunnerType,
                .amqp => return error.WrongRunnerType,
                .awf => return error.WrongRunnerType,
                .http => return error.WrongRunnerType,
                .redis => return error.WrongRunnerType,
            }
        },
        else => return error.WrongInstructionType,
    }
}

test "build_instruction parses RULE SET command with direct runner and multiple args" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.curl"), @constCast("curl.*"), @constCast("direct"), @constCast("/usr/bin/curl"), @constCast("-s"), @constCast("http://example.com") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .rule_set => |r| {
            switch (r.runner) {
                .direct => |d| {
                    try std.testing.expectEqualStrings("/usr/bin/curl", d.executable);
                    try std.testing.expectEqual(@as(usize, 2), d.args.len);
                    try std.testing.expectEqualStrings("-s", d.args[0]);
                    try std.testing.expectEqualStrings("http://example.com", d.args[1]);
                },
                .shell => return error.WrongRunnerType,
                .amqp => return error.WrongRunnerType,
                .awf => return error.WrongRunnerType,
                .http => return error.WrongRunnerType,
                .redis => return error.WrongRunnerType,
            }
        },
        else => return error.WrongInstructionType,
    }
}

test "free_instruction_strings frees rule_set direct runner strings without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule.exec");
    const pattern = try allocator.dupe(u8, "exec.*");
    const executable = try allocator.dupe(u8, "/bin/echo");
    const args = try allocator.alloc([]const u8, 0);
    const instr = instruction.Instruction{ .rule_set = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .direct = .{ .executable = executable, .args = args } },
    } };
    free_instruction_strings(allocator, instr);
}

test "free_instruction_strings frees rule_set direct runner with args without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule.curl");
    const pattern = try allocator.dupe(u8, "curl.*");
    const executable = try allocator.dupe(u8, "/usr/bin/curl");
    const args = try allocator.alloc([]const u8, 2);
    args[0] = try allocator.dupe(u8, "-s");
    args[1] = try allocator.dupe(u8, "http://example.com");
    const instr = instruction.Instruction{ .rule_set = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .direct = .{ .executable = executable, .args = args } },
    } };
    free_instruction_strings(allocator, instr);
}

test "build_instruction returns null for RULE SET with direct runner missing executable" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.exec"), @constCast("exec.*"), @constCast("direct") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "build_instruction returns null for SET without timestamp" {
    var args = [_][]u8{ @constCast("SET"), @constCast("backup.daily") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "response router silently ignores response for unregistered client" {
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    const req = query.Request{
        .client = 999,
        .identifier = "req1",
        .instruction = .{ .get = .{ .identifier = "job.1" } },
    };
    const resp = query.Response{ .request = req, .success = true };
    router.route(resp);
}

test "response router drops response on full channel without crash" {
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    var ch = try Channel(query.Response).init(std.testing.allocator, std.testing.io, 1);
    defer ch.deinit();

    const client_id = @as(query.Client, 5);
    try router.register(client_id, &ch);

    const req = query.Request{
        .client = client_id,
        .identifier = "r1",
        .instruction = .{ .get = .{ .identifier = "j1" } },
    };
    const first = query.Response{ .request = req, .success = true };
    const second = query.Response{ .request = req, .success = false };

    router.route(first);
    router.route(second); // channel full — silently dropped, must not crash

    router.deregister(client_id);
    const received = ch.try_receive();
    try std.testing.expect(received != null);
    try std.testing.expect(received.?.success);
}

test "handle_connection passes peer address and exits cleanly" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    pair.close();

    handle_connection(
        std.testing.allocator,
        std.testing.io,
        Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        99,
        &req_ch,
        &router,
        null,
    );
}

test "write_response formats list_rules empty result as OK only" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

    const req = query.Request{
        .client = 0,
        .identifier = "r1",
        .instruction = .{ .list_rules = .{} },
    };
    const resp = query.Response{
        .request = req,
        .success = true,
        .body = null,
    };

    try write_response(std.testing.allocator, Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } }, resp);
    pair.close();

    var buf: [128]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    try std.testing.expectEqualStrings("r1 OK\n", buf[0..n]);
}

test "handle_connection forwards SET instruction to request channel" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    try pair.writeAll("r1 SET job.backup 1595586600000000000\n");
    pair.close();

    const Context = struct {
        received_tag: []const u8 = "",

        fn respond(self: *@This(), rch: *Channel(query.Request), rtr: *ResponseRouter) void {
            if (rch.receive()) |req| {
                self.received_tag = @tagName(req.instruction);
                // In production the scheduler owns instruction strings; free them here to avoid leak.
                free_instruction_strings(std.testing.allocator, req.instruction);
                const resp = query.Response{ .request = req, .success = true };
                rtr.route(resp);
                // handle_connection frees resp.request.identifier after receiving the response.
            }
        }
    };

    var ctx = Context{};
    const t = try std.Thread.spawn(.{}, Context.respond, .{ &ctx, &req_ch, &router });

    handle_connection(
        std.testing.allocator,
        std.testing.io,
        Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        42,
        &req_ch,
        &router,
        null,
    );

    t.join();

    try std.testing.expectEqualStrings("set", ctx.received_tag);
}

test "handle_connection forwards LISTRULES instruction to request channel" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    try pair.writeAll("r2 LISTRULES\n");
    pair.close();

    const Context = struct {
        received_tag: []const u8 = "",

        fn respond(self: *@This(), rch: *Channel(query.Request), rtr: *ResponseRouter) void {
            if (rch.receive()) |req| {
                self.received_tag = @tagName(req.instruction);
                // list_rules has no strings to free.
                const resp = query.Response{ .request = req, .success = true };
                rtr.route(resp);
            }
        }
    };

    var ctx = Context{};
    const t = try std.Thread.spawn(.{}, Context.respond, .{ &ctx, &req_ch, &router });

    handle_connection(
        std.testing.allocator,
        std.testing.io,
        Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        43,
        &req_ch,
        &router,
        null,
    );

    t.join();

    try std.testing.expectEqualStrings("list_rules", ctx.received_tag);
}

test "plain Connection read returns data from underlying socket" {
    const pair = try make_socket_pair();

    try pair.writeAll("hello");
    pair.close();

    const conn = Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } };
    var buf: [16]u8 = undefined;
    const n = try conn.read(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "plain Connection write delivers data through socket" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

    const conn = Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } };
    _ = try conn.write("world");
    conn.close();

    var buf: [16]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    try std.testing.expectEqualStrings("world", buf[0..n]);
}

test "write_response accepts plain Connection and formats OK response" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

    const conn = Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } };
    const req = query.Request{
        .client = 0,
        .identifier = "r1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 0 } },
    };
    const resp = query.Response{ .request = req, .success = true, .body = null };

    try write_response(std.testing.allocator, conn, resp);
    conn.close();

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    try std.testing.expectEqualStrings("r1 OK\n", buf[0..n]);
}

test "handle_connection accepts plain Connection and exits cleanly" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    pair.close();

    handle_connection(
        std.testing.allocator,
        std.testing.io,
        Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        100,
        &req_ch,
        &router,
        null,
    );
}

test "tcp server initializes with null instruments" {
    var running = std.atomic.Value(bool).init(true);
    var active = std.atomic.Value(usize).init(0);
    const server = TcpServer.init(std.testing.allocator, "127.0.0.1:5678", &running, null, &active, null);
    try std.testing.expectEqual(@as(?telemetry.Instruments, null), server.instruments);
}

test "tcp server set_instruments makes instruments non-null" {
    const sdk = @import("opentelemetry");
    var running = std.atomic.Value(bool).init(true);
    var active = std.atomic.Value(usize).init(0);
    var server = TcpServer.init(std.testing.allocator, "127.0.0.1:5678", &running, null, &active, null);

    const meter_provider = try sdk.metrics.MeterProvider.init(std.testing.allocator, std.testing.io);
    defer meter_provider.shutdown();
    const tracer_provider = try sdk.trace.TracerProvider.init(
        std.testing.allocator,
        std.testing.io,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init((std.Random.IoSource{ .io = std.testing.io }).interface()) },
    );
    defer tracer_provider.shutdown();
    const instruments = try telemetry.createInstruments(meter_provider, tracer_provider);

    server.set_instruments(instruments);
    try std.testing.expect(server.instruments != null);
}

test "connection_worker decrements active_connections on exit" {
    const sdk = @import("opentelemetry");
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    const meter_provider = try sdk.metrics.MeterProvider.init(std.testing.allocator, std.testing.io);
    defer meter_provider.shutdown();
    const tracer_provider = try sdk.trace.TracerProvider.init(
        std.testing.allocator,
        std.testing.io,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init((std.Random.IoSource{ .io = std.testing.io }).interface()) },
    );
    defer tracer_provider.shutdown();
    const instruments = try telemetry.createInstruments(meter_provider, tracer_provider);

    var active = std.atomic.Value(usize).init(1);

    pair.close();
    connection_worker(
        &active,
        instruments,
        std.testing.allocator,
        std.testing.io,
        make_stream(pair.read_fd),
        200,
        &req_ch,
        &router,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 0), active.load(.acquire));
}

test "build_instruction parses STAT command" {
    var args = [_][]u8{@constCast("STAT")};
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    switch (instr) {
        .stat => {},
        else => return error.WrongInstructionType,
    }
}

test "build_instruction parses STAT command ignoring trailing args" {
    var args = [_][]u8{ @constCast("STAT"), @constCast("ignored") };
    const result = parser.ParseResult{
        .command = @constCast("req1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    switch (instr) {
        .stat => {},
        else => return error.WrongInstructionType,
    }
}

test "free_instruction_strings does not leak for stat instruction" {
    const instr = instruction.Instruction{ .stat = .{} };
    free_instruction_strings(std.testing.allocator, instr);
}

test "write_response formats stat multi-line metrics body with request_id prefix" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

    const req = query.Request{
        .client = 0,
        .identifier = "req-1",
        .instruction = .{ .stat = .{} },
    };
    const resp = query.Response{
        .request = req,
        .success = true,
        .body = "uptime_ns 60000000000\nconnections 1\njobs_total 5\n",
    };

    try write_response(std.testing.allocator, Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } }, resp);
    pair.close();

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    const output = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, output, "req-1 uptime_ns 60000000000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "req-1 connections 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "req-1 jobs_total 5\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "req-1 OK\n"));
}

test "write_response formats stat error response as ERROR line" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

    const req = query.Request{
        .client = 0,
        .identifier = "req-1",
        .instruction = .{ .stat = .{} },
    };
    const resp = query.Response{
        .request = req,
        .success = false,
        .body = null,
        .error_code = .internal,
    };

    try write_response(std.testing.allocator, Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } }, resp);
    pair.close();

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    try std.testing.expectEqualStrings("req-1 ERROR internal\n", buf[0..n]);
}

test "write_response formats error with code and message for single-entity instruction" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

    const req = query.Request{
        .client = 0,
        .identifier = "req-1",
        .instruction = .{ .get = .{ .identifier = "job.x" } },
    };
    const resp = query.Response{
        .request = req,
        .success = false,
        .error_code = .not_found,
        .error_message = "job \"x\" does not exist",
    };

    try write_response(std.testing.allocator, Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } }, resp);
    pair.close();

    var buf: [128]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    try std.testing.expectEqualStrings("req-1 ERROR not_found job \"x\" does not exist\n", buf[0..n]);
}

test "write_response formats error with code only when message is null" {
    const pair = try make_socket_pair();
    defer _ = std.os.linux.close(pair.read_fd);

    const req = query.Request{
        .client = 0,
        .identifier = "req-2",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 0 } },
    };
    const resp = query.Response{
        .request = req,
        .success = false,
        .error_code = .internal,
        .error_message = null,
    };

    try write_response(std.testing.allocator, Connection{ .plain = .{ .stream = make_stream(pair.write_fd) } }, resp);
    pair.close();

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(pair.read_fd, &buf);
    try std.testing.expectEqualStrings("req-2 ERROR internal\n", buf[0..n]);
}

test "handle_connection forwards STAT instruction to request channel" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    try pair.writeAll("r3 STAT\n");
    pair.close();

    const Context = struct {
        received_tag: []const u8 = "",

        fn respond(self: *@This(), rch: *Channel(query.Request), rtr: *ResponseRouter) void {
            if (rch.receive()) |req| {
                self.received_tag = @tagName(req.instruction);
                const resp = query.Response{ .request = req, .success = true };
                rtr.route(resp);
            }
        }
    };

    var ctx = Context{};
    const t = try std.Thread.spawn(.{}, Context.respond, .{ &ctx, &req_ch, &router });

    handle_connection(
        std.testing.allocator,
        std.testing.io,
        Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        44,
        &req_ch,
        &router,
        null,
    );

    t.join();

    try std.testing.expectEqualStrings("stat", ctx.received_tag);
}

test "connection_worker with null instruments decrements active_connections on exit" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    var active = std.atomic.Value(usize).init(1);

    pair.close();
    connection_worker(
        &active,
        null,
        std.testing.allocator,
        std.testing.io,
        make_stream(pair.read_fd),
        201,
        &req_ch,
        &router,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 0), active.load(.acquire));
}

test "handle_connection forwards stat bypassing namespace authorization without sending error" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    try pair.writeAll("r99 STAT\n");
    pair.close();

    const Context = struct {
        forwarded: bool = false,

        fn respond(self: *@This(), rch: *Channel(query.Request), rtr: *ResponseRouter) void {
            if (rch.receive()) |req| {
                self.forwarded = std.mem.eql(u8, @tagName(req.instruction), "stat");
                const resp = query.Response{ .request = req, .success = true, .body = null };
                rtr.route(resp);
            }
        }
    };

    var ctx = Context{};
    const t = try std.Thread.spawn(.{}, Context.respond, .{ &ctx, &req_ch, &router });

    handle_connection(
        std.testing.allocator,
        std.testing.io,
        Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        202,
        &req_ch,
        &router,
        null,
    );

    t.join();

    try std.testing.expect(ctx.forwarded);
}

test "build_instruction parses RULE SET command with awf runner and no inputs" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.review"), @constCast("app."), @constCast("awf"), @constCast("code-review") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .rule_set => |r| {
            try std.testing.expectEqualStrings("rule.review", r.identifier);
            try std.testing.expectEqualStrings("app.", r.pattern);
            switch (r.runner) {
                .awf => |awf| {
                    try std.testing.expectEqualStrings("code-review", awf.workflow);
                    try std.testing.expectEqual(@as(usize, 0), awf.inputs.len);
                },
                .shell => return error.WrongRunnerType,
                .amqp => return error.WrongRunnerType,
                .direct => return error.WrongRunnerType,
                .http => return error.WrongRunnerType,
                .redis => return error.WrongRunnerType,
            }
        },
        else => return error.WrongInstructionType,
    }
}

test "build_instruction parses RULE SET command with awf runner and --input flags" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.report"), @constCast("report."), @constCast("awf"), @constCast("generate-report"), @constCast("--input"), @constCast("format=pdf"), @constCast("--input"), @constCast("target=main") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .rule_set => |r| {
            switch (r.runner) {
                .awf => |awf| {
                    try std.testing.expectEqualStrings("generate-report", awf.workflow);
                    try std.testing.expectEqual(@as(usize, 2), awf.inputs.len);
                    try std.testing.expectEqualStrings("format=pdf", awf.inputs[0]);
                    try std.testing.expectEqualStrings("target=main", awf.inputs[1]);
                },
                .shell => return error.WrongRunnerType,
                .amqp => return error.WrongRunnerType,
                .direct => return error.WrongRunnerType,
                .http => return error.WrongRunnerType,
                .redis => return error.WrongRunnerType,
            }
        },
        else => return error.WrongInstructionType,
    }
}

test "build_instruction returns null for RULE SET with awf runner missing workflow" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.review"), @constCast("app."), @constCast("awf") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "build_instruction returns null for RULE SET with awf --input flag missing value" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.report"), @constCast("report."), @constCast("awf"), @constCast("generate-report"), @constCast("--input") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "build_instruction returns null for RULE SET with awf runner and non-input flag" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.report"), @constCast("report."), @constCast("awf"), @constCast("generate-report"), @constCast("--output"), @constCast("file.txt") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "free_instruction_strings frees rule_set awf runner strings without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule.review");
    const pattern = try allocator.dupe(u8, "app.");
    const workflow = try allocator.dupe(u8, "code-review");
    const input0 = try allocator.dupe(u8, "format=pdf");
    const inputs = try allocator.alloc([]const u8, 1);
    inputs[0] = input0;
    const instr = instruction.Instruction{ .rule_set = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .awf = .{ .workflow = workflow, .inputs = inputs } },
    } };
    free_instruction_strings(allocator, instr);
}

test "build_instruction parses RULE SET command with http runner GET method" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.ping"), @constCast("health."), @constCast("http"), @constCast("GET"), @constCast("https://api.internal/trigger") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .rule_set => |r| {
            try std.testing.expectEqualStrings("rule.ping", r.identifier);
            try std.testing.expectEqualStrings("health.", r.pattern);
            switch (r.runner) {
                .http => |h| {
                    try std.testing.expectEqualStrings("GET", h.method);
                    try std.testing.expectEqualStrings("https://api.internal/trigger", h.url);
                },
                .shell => return error.WrongRunnerType,
                .amqp => return error.WrongRunnerType,
                .direct => return error.WrongRunnerType,
                .awf => return error.WrongRunnerType,
                .redis => return error.WrongRunnerType,
            }
        },
        else => return error.WrongInstructionType,
    }
}

test "build_instruction parses RULE SET command with http runner POST method" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.notify"), @constCast("deploy."), @constCast("http"), @constCast("POST"), @constCast("https://hooks.example.com/webhook") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .rule_set => |r| {
            switch (r.runner) {
                .http => |h| {
                    try std.testing.expectEqualStrings("POST", h.method);
                    try std.testing.expectEqualStrings("https://hooks.example.com/webhook", h.url);
                },
                else => return error.WrongRunnerType,
            }
        },
        else => return error.WrongInstructionType,
    }
}

test "build_instruction returns null for RULE SET with http runner missing url" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.ping"), @constCast("health."), @constCast("http"), @constCast("GET") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "build_instruction returns null for RULE SET with http runner unsupported method" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.ping"), @constCast("health."), @constCast("http"), @constCast("PATCH"), @constCast("https://api.internal/trigger") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "build_instruction returns null for RULE SET with http runner invalid url scheme" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.ping"), @constCast("health."), @constCast("http"), @constCast("GET"), @constCast("ftp://api.internal/trigger") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "free_instruction_strings frees rule_set http runner strings without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule.notify");
    const pattern = try allocator.dupe(u8, "deploy.");
    const method = try allocator.dupe(u8, "POST");
    const url = try allocator.dupe(u8, "https://hooks.example.com/webhook");
    const instr = instruction.Instruction{ .rule_set = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .http = .{ .method = method, .url = url } },
    } };
    free_instruction_strings(allocator, instr);
}

test "handle_connection forwards non-stat instruction through namespace authorization check" {
    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();

    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    try pair.writeAll("r100 QUERY jobs\n");
    pair.close();

    const Context = struct {
        forwarded: bool = false,

        fn respond(self: *@This(), rch: *Channel(query.Request), rtr: *ResponseRouter) void {
            if (rch.receive()) |req| {
                self.forwarded = std.mem.eql(u8, @tagName(req.instruction), "query");
                free_instruction_strings(std.testing.allocator, req.instruction);
                rtr.route(query.Response{ .request = req, .success = true, .body = null });
            }
        }
    };

    var ctx = Context{};
    const t = try std.Thread.spawn(.{}, Context.respond, .{ &ctx, &req_ch, &router });

    handle_connection(
        std.testing.allocator,
        std.testing.io,
        Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        203,
        &req_ch,
        &router,
        null,
    );

    t.join();

    try std.testing.expect(ctx.forwarded);
}

fn poll_for_response(fd: std.posix.socket_t, buf: []u8, timeout_ms: i32) !usize {
    var pfd = [1]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pfd, timeout_ms);
    if (ready == 0) return 0;
    return try std.posix.read(fd, buf);
}

const HCThread = struct {
    conn: Connection,
    client_id: u128,
    req_ch: *Channel(query.Request),
    router: *ResponseRouter,
    store: ?*TokenStore,

    fn run(self: @This()) void {
        handle_connection(
            std.testing.allocator,
            std.testing.io,
            self.conn,
            self.client_id,
            self.req_ch,
            self.router,
            self.store,
        );
    }
};

const EchoScheduler = struct {
    req_ch: *Channel(query.Request),
    router: *ResponseRouter,

    fn run(self: @This()) void {
        while (self.req_ch.receive()) |req| {
            // In production the scheduler owns instruction strings; free them here to avoid leak.
            free_instruction_strings(std.testing.allocator, req.instruction);
            const resp = query.Response{ .request = req, .success = true };
            self.router.route(resp);
        }
    }
};

test "handle_connection AUTH with valid token responds OK" {
    const tokens = [_]domain.auth.Token{
        .{ .name = "deploy", .secret = "sk_deploy_abc", .namespace = "deploy." },
    };
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    try store.load(&tokens);

    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    try pair.writeAll("AUTH sk_deploy_abc\n");

    const t = try std.Thread.spawn(.{}, HCThread.run, .{HCThread{
        .conn = Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        .client_id = 300,
        .req_ch = &req_ch,
        .router = &router,
        .store = @as(?*TokenStore, &store),
    }});
    defer t.join();
    defer pair.close();

    var buf: [64]u8 = undefined;
    const n = try poll_for_response(pair.write_fd, &buf, 500);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings("OK\n", buf[0..n]);
}

test "handle_connection AUTH with invalid token responds ERROR and closes connection" {
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();

    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    try pair.writeAll("AUTH bad_secret_xyz\n");

    const t = try std.Thread.spawn(.{}, HCThread.run, .{HCThread{
        .conn = Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        .client_id = 301,
        .req_ch = &req_ch,
        .router = &router,
        .store = @as(?*TokenStore, &store),
    }});
    defer t.join();
    defer pair.close();

    var buf: [64]u8 = undefined;
    const n = try poll_for_response(pair.write_fd, &buf, 500);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings("ERROR auth_failed\n", buf[0..n]);
}

test "handle_connection non-AUTH first command responds ERROR and closes connection" {
    const tokens = [_]domain.auth.Token{
        .{ .name = "deploy", .secret = "sk_deploy_abc", .namespace = "deploy." },
    };
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    try store.load(&tokens);

    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    const sched = EchoScheduler{ .req_ch = &req_ch, .router = &router };
    const t_sched = try std.Thread.spawn(.{}, EchoScheduler.run, .{sched});
    defer t_sched.join();
    defer req_ch.close();

    try pair.writeAll("r1 SET deploy.job 12345\n");

    const t = try std.Thread.spawn(.{}, HCThread.run, .{HCThread{
        .conn = Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        .client_id = 302,
        .req_ch = &req_ch,
        .router = &router,
        .store = @as(?*TokenStore, &store),
    }});
    defer t.join();
    defer pair.close();

    var buf: [64]u8 = undefined;
    const n = try poll_for_response(pair.write_fd, &buf, 500);
    try std.testing.expect(n > 0);
    try std.testing.expectEqualStrings("ERROR auth_required\n", buf[0..n]);
}

test "handle_connection command within namespace is accepted after AUTH" {
    const tokens = [_]domain.auth.Token{
        .{ .name = "deploy", .secret = "sk_deploy_ns", .namespace = "deploy." },
    };
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    try store.load(&tokens);

    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    const sched = EchoScheduler{ .req_ch = &req_ch, .router = &router };
    const t_sched = try std.Thread.spawn(.{}, EchoScheduler.run, .{sched});
    defer t_sched.join();
    defer req_ch.close();

    try pair.writeAll("AUTH sk_deploy_ns\n");

    const t = try std.Thread.spawn(.{}, HCThread.run, .{HCThread{
        .conn = Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        .client_id = 303,
        .req_ch = &req_ch,
        .router = &router,
        .store = @as(?*TokenStore, &store),
    }});
    defer t.join();
    defer pair.close();

    var buf: [128]u8 = undefined;
    const n_auth = try poll_for_response(pair.write_fd, &buf, 500);
    try std.testing.expect(n_auth > 0);
    try std.testing.expectEqualStrings("OK\n", buf[0..n_auth]);

    try pair.writeAll("r1 SET deploy.release.1 12345\n");

    var buf2: [64]u8 = undefined;
    const n_cmd = try poll_for_response(pair.write_fd, &buf2, 500);
    try std.testing.expect(n_cmd > 0);
    try std.testing.expectEqualStrings("r1 OK\n", buf2[0..n_cmd]);
}

test "handle_connection command outside namespace responds ERROR after AUTH" {
    const tokens = [_]domain.auth.Token{
        .{ .name = "deploy", .secret = "sk_deploy_ns2", .namespace = "deploy." },
    };
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    try store.load(&tokens);

    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    const sched = EchoScheduler{ .req_ch = &req_ch, .router = &router };
    const t_sched = try std.Thread.spawn(.{}, EchoScheduler.run, .{sched});
    defer t_sched.join();
    defer req_ch.close();

    try pair.writeAll("AUTH sk_deploy_ns2\n");

    const t = try std.Thread.spawn(.{}, HCThread.run, .{HCThread{
        .conn = Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        .client_id = 304,
        .req_ch = &req_ch,
        .router = &router,
        .store = @as(?*TokenStore, &store),
    }});
    defer t.join();
    defer pair.close();

    var buf: [64]u8 = undefined;
    const n_auth = try poll_for_response(pair.write_fd, &buf, 500);
    try std.testing.expect(n_auth > 0);
    try std.testing.expectEqualStrings("OK\n", buf[0..n_auth]);

    try pair.writeAll("r2 SET backup.daily 12345\n");

    var buf2: [64]u8 = undefined;
    const n_cmd = try poll_for_response(pair.write_fd, &buf2, 500);
    try std.testing.expect(n_cmd > 0);
    try std.testing.expectEqualStrings("r2 ERROR auth_denied insufficient namespace scope\n", buf2[0..n_cmd]);
}

test "handle_connection QUERY results filtered to client namespace after AUTH" {
    const tokens = [_]domain.auth.Token{
        .{ .name = "deploy", .secret = "sk_deploy_query", .namespace = "deploy." },
    };
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    try store.load(&tokens);

    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    const QueryScheduler = struct {
        rch: *Channel(query.Request),
        rtr: *ResponseRouter,

        fn run(self: @This()) void {
            if (self.rch.receive()) |req| {
                // In production the scheduler owns instruction strings; free them here to avoid leak.
                free_instruction_strings(std.testing.allocator, req.instruction);
                const body = std.testing.allocator.dupe(u8, "deploy.job1 planned 1595586600000000000\nbackup.daily planned 1595586700000000000\n") catch return;
                const resp = query.Response{ .request = req, .success = true, .body = body };
                self.rtr.route(resp);
            }
        }
    };
    const t_sched = try std.Thread.spawn(.{}, QueryScheduler.run, .{QueryScheduler{
        .rch = &req_ch,
        .rtr = &router,
    }});
    defer t_sched.join();
    defer req_ch.close();

    try pair.writeAll("AUTH sk_deploy_query\n");

    const t = try std.Thread.spawn(.{}, HCThread.run, .{HCThread{
        .conn = Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        .client_id = 305,
        .req_ch = &req_ch,
        .router = &router,
        .store = @as(?*TokenStore, &store),
    }});
    defer t.join();
    defer pair.close();

    var buf: [64]u8 = undefined;
    const n_auth = try poll_for_response(pair.write_fd, &buf, 500);
    try std.testing.expect(n_auth > 0);
    try std.testing.expectEqualStrings("OK\n", buf[0..n_auth]);

    try pair.writeAll("r3 QUERY *\n");

    var resp_buf: [512]u8 = undefined;
    var total: usize = 0;
    for (0..10) |_| {
        const n = try poll_for_response(pair.write_fd, resp_buf[total..], 200);
        if (n == 0) break;
        total += n;
        if (std.mem.endsWith(u8, resp_buf[0..total], "r3 OK\n")) break;
    }
    try std.testing.expect(total > 0);
    const output = resp_buf[0..total];
    try std.testing.expect(std.mem.indexOf(u8, output, "deploy.job1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "backup.daily") == null);
}

test "handle_connection RULE SET with identifier in namespace succeeds regardless of pattern namespace" {
    const tokens = [_]domain.auth.Token{
        .{ .name = "deploy", .secret = "sk_deploy_rule", .namespace = "deploy." },
    };
    var store = TokenStore.init(std.testing.allocator);
    defer store.deinit();
    try store.load(&tokens);

    const pair = try make_socket_pair();

    var req_ch = try Channel(query.Request).init(std.testing.allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(std.testing.allocator, std.testing.io);
    defer router.deinit();

    const sched = EchoScheduler{ .req_ch = &req_ch, .router = &router };
    const t_sched = try std.Thread.spawn(.{}, EchoScheduler.run, .{sched});
    defer t_sched.join();
    defer req_ch.close();

    try pair.writeAll("AUTH sk_deploy_rule\n");

    const t = try std.Thread.spawn(.{}, HCThread.run, .{HCThread{
        .conn = Connection{ .plain = .{ .stream = make_stream(pair.read_fd) } },
        .client_id = 306,
        .req_ch = &req_ch,
        .router = &router,
        .store = @as(?*TokenStore, &store),
    }});
    defer t.join();
    defer pair.close();

    var buf: [64]u8 = undefined;
    const n_auth = try poll_for_response(pair.write_fd, &buf, 500);
    try std.testing.expect(n_auth > 0);
    try std.testing.expectEqualStrings("OK\n", buf[0..n_auth]);

    try pair.writeAll("r4 RULE SET deploy.rule backup. shell echo ok\n");

    var buf2: [64]u8 = undefined;
    const n_cmd = try poll_for_response(pair.write_fd, &buf2, 500);
    try std.testing.expect(n_cmd > 0);
    try std.testing.expectEqualStrings("r4 OK\n", buf2[0..n_cmd]);
}

test "build_instruction parses RULE SET command with redis runner PUBLISH command" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.notify"), @constCast("deploy."), @constCast("redis"), @constCast("redis://localhost:6379/0"), @constCast("PUBLISH"), @constCast("deploy:events") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = (try build_instruction(std.testing.allocator, result)).?;
    defer free_instruction_strings(std.testing.allocator, instr);
    switch (instr) {
        .rule_set => |r| {
            try std.testing.expectEqualStrings("rule.notify", r.identifier);
            try std.testing.expectEqualStrings("deploy.", r.pattern);
            switch (r.runner) {
                .redis => |redis| {
                    try std.testing.expectEqualStrings("redis://localhost:6379/0", redis.url);
                    try std.testing.expectEqualStrings("PUBLISH", redis.command);
                    try std.testing.expectEqualStrings("deploy:events", redis.key);
                },
                else => return error.WrongRunnerType,
            }
        },
        else => return error.WrongInstructionType,
    }
}

test "build_instruction returns null for RULE SET with redis runner unsupported command" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.flush"), @constCast("all."), @constCast("redis"), @constCast("redis://localhost:6379/0"), @constCast("FLUSHALL"), @constCast("ignored") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "build_instruction returns null for RULE SET with redis runner invalid url scheme" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.notify"), @constCast("deploy."), @constCast("redis"), @constCast("amqp://localhost:5672"), @constCast("PUBLISH"), @constCast("deploy:events") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "build_instruction returns null for RULE SET with redis runner too few tokens" {
    var args = [_][]u8{ @constCast("RULE"), @constCast("SET"), @constCast("rule.notify"), @constCast("deploy."), @constCast("redis"), @constCast("redis://localhost:6379/0"), @constCast("PUBLISH") };
    const result = parser.ParseResult{
        .command = @constCast("r1"),
        .args = &args,
        .remaining = "",
    };
    const instr = try build_instruction(std.testing.allocator, result);
    try std.testing.expect(instr == null);
}

test "free_instruction_strings frees rule_set redis runner strings without leak" {
    const allocator = std.testing.allocator;
    const id = try allocator.dupe(u8, "rule.notify");
    const pattern = try allocator.dupe(u8, "deploy.");
    const url = try allocator.dupe(u8, "redis://localhost:6379/0");
    const command = try allocator.dupe(u8, "PUBLISH");
    const key = try allocator.dupe(u8, "deploy:events");
    const instr = instruction.Instruction{ .rule_set = .{
        .identifier = id,
        .pattern = pattern,
        .runner = .{ .redis = .{ .url = url, .command = command, .key = key } },
    } };
    free_instruction_strings(allocator, instr);
}
