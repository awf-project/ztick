const std = @import("std");
const domain = @import("domain.zig");
const application = @import("application.zig");
const infrastructure = @import("infrastructure.zig");
const interfaces = @import("interfaces.zig");

const query = domain.query;
const execution = domain.execution;
const instruction = domain.instruction;

const persistence_backend = infrastructure.persistence.backend;
const infrastructure_persistence_background = infrastructure.persistence.background;
const infrastructure_channel = infrastructure.channel;
const infrastructure_clock = infrastructure.clock;
const infrastructure_tcp_server = infrastructure.tcp_server;
const infrastructure_http = infrastructure.http;
const infrastructure_tls_context = infrastructure.tls_context;
const infrastructure_telemetry = infrastructure.telemetry;
const infrastructure_auth = infrastructure.auth;
const infrastructure_runner = infrastructure.runner;

const interfaces_config = interfaces.config;
const interfaces_cli = interfaces.cli;
const interfaces_dump = interfaces.dump;

const application_scheduler = application.scheduler;
const application_token_store = application.token_store;

var runtime_log_level: ?std.log.Level = null;

var global_running: *std.atomic.Value(bool) = undefined;
var global_listen_fd: std.atomic.Value(std.posix.socket_t) = std.atomic.Value(std.posix.socket_t).init(-1);
var global_http_listen_fd: std.atomic.Value(std.posix.socket_t) = std.atomic.Value(std.posix.socket_t).init(-1);

fn signal_handler(_: std.os.linux.SIG) callconv(.c) void {
    global_running.store(false, .release);
    const fd = global_listen_fd.load(.acquire);
    if (fd != -1) _ = std.os.linux.shutdown(fd, 2);
    const http_fd = global_http_listen_fd.load(.acquire);
    if (http_fd != -1) _ = std.os.linux.shutdown(http_fd, 2);
}

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = log_fn,
};

fn log_fn_write(
    writer: anytype,
    comptime level: std.log.Level,
    comptime format: []const u8,
    args: anytype,
) void {
    const threshold = runtime_log_level orelse return;
    if (@intFromEnum(level) > @intFromEnum(threshold)) return;
    const level_name = comptime switch (level) {
        .err => "ERROR",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DEBUG",
    };
    writer.print("[" ++ level_name ++ "] " ++ format ++ "\n", args) catch return;
}

fn log_fn(
    comptime level: std.log.Level,
    comptime scope: anytype,
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    log_fn_write(&w, level, format, args);
    const msg = w.buffered();
    if (msg.len > 0) _ = std.os.linux.write(2, msg.ptr, msg.len);
}

const Channel = infrastructure_channel.Channel;
const TcpServer = infrastructure_tcp_server.TcpServer;
const BackendState = persistence_backend.BackendState;
const Scheduler = application_scheduler.SchedulerWith(BackendState);
const Clock = infrastructure_clock.Clock;

test {
    _ = domain;
    _ = application;
    _ = infrastructure;
    _ = interfaces;
}

const ResponseRouter = infrastructure_tcp_server.ResponseRouter;

fn log_level_to_std(level: interfaces_config.LogLevel) ?std.log.Level {
    return switch (level) {
        .info => .info,
        .warn => .warn,
        .debug => .debug,
        .@"error" => .err,
        .trace => .debug,
        .off => null,
    };
}

const ControllerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    address: []const u8,
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    running: *std.atomic.Value(bool),
    tls_context: ?*infrastructure_tls_context.TlsContext,
    token_store: ?*application_token_store.TokenStore,
    instruments: ?infrastructure_telemetry.Instruments,
    active_connections: *std.atomic.Value(usize),
    /// Passed to TcpServer.signal_listen_fd so the signal handler can close
    /// the listen socket to unblock accept() on SIGINT/SIGTERM.
    signal_listen_fd: *std.atomic.Value(std.posix.socket_t),
};

const DatabaseContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    framerate: u16,
    /// The raw backend is stored here so run_database can wrap it in BackendState.
    backend: persistence_backend.PersistenceBackend,
    compression_interval_ns: u64,
    running: *std.atomic.Value(bool),
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    exec_request_ch: *Channel(execution.Request),
    exec_response_ch: *Channel(execution.Response),
    instruments: ?infrastructure_telemetry.Instruments,
    startup_ns: i128,
    active_connections: *std.atomic.Value(usize),
    auth_enabled: bool,
    tls_enabled: bool,
};

const ProcessorContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    exec_request_ch: *Channel(execution.Request),
    exec_response_ch: *Channel(execution.Response),
    shell_config: interfaces_config.ShellConfig,
};

const HttpControllerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    address: []const u8,
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    running: *std.atomic.Value(bool),
    bearer_token: ?[]const u8,
    signal_listen_fd: *std.atomic.Value(std.posix.socket_t),
};

fn run_http_controller(ctx: HttpControllerContext) void {
    var server = infrastructure_http.HttpServer.init(
        ctx.allocator,
        ctx.io,
        ctx.address,
        ctx.running,
        ctx.request_ch,
        ctx.response_router,
        ctx.bearer_token,
    );
    server.signal_listen_fd = ctx.signal_listen_fd;
    server.start(ctx.io) catch |err| {
        std.log.err("http controller: start failed: {}", .{err});
        return;
    };
    server.join_all();
}

fn run_controller(ctx: ControllerContext) void {
    var server = TcpServer.init(ctx.allocator, ctx.address, ctx.running, ctx.tls_context, ctx.active_connections, ctx.token_store);
    server.signal_listen_fd = ctx.signal_listen_fd;
    if (ctx.instruments) |instr| server.set_instruments(instr);
    defer server.deinit();
    server.start(ctx.io, ctx.request_ch, ctx.response_router) catch |err| {
        std.log.err("controller: start failed: {}", .{err});
        return;
    };
    server.join_all(ctx.io);
}

pub fn compress_startup_leftover(io: std.Io, allocator: std.mem.Allocator, backend: persistence_backend.PersistenceBackend) void {
    const lf = switch (backend) {
        .logfile => |lf| lf,
        .memory => return,
    };
    const dir = lf.logfile_dir orelse return;
    const filenames = infrastructure_persistence_background.Filenames{};
    const f = dir.openFile(io, filenames.source, .{}) catch return;
    f.close(io);
    infrastructure_persistence_background.compress(allocator, io, dir, filenames) catch {
        std.log.warn("startup: leftover .to_compress compression failed", .{});
    };
}

fn run_database(ctx: DatabaseContext) void {
    const backend_state = BackendState.init(ctx.backend);
    var scheduler = Scheduler.init(ctx.allocator);
    scheduler.persistence = backend_state;
    scheduler.compression_interval_ns = ctx.compression_interval_ns;
    if (ctx.instruments) |instr| scheduler.set_instruments(instr);
    scheduler.set_stat_context(ctx.io, ctx.startup_ns, ctx.active_connections, ctx.auth_enabled, ctx.tls_enabled, ctx.framerate);
    defer scheduler.deinit();

    scheduler.load(ctx.allocator) catch |err| {
        std.log.warn("database: load failed: {}", .{err});
    };

    compress_startup_leftover(ctx.io, ctx.allocator, ctx.backend);
    std.log.info("loaded {d} jobs, {d} rules", .{
        scheduler.job_storage.count(),
        scheduler.rule_storage.count(),
    });

    var wake_mutex: std.Io.Mutex = .init;
    var wake_token = std.atomic.Value(u32).init(0);
    ctx.request_ch.wake_token = &wake_token;
    const clock = Clock.init(ctx.framerate, ctx.running, ctx.io);
    clock.start(TickContext{
        .scheduler = &scheduler,
        .request_ch = ctx.request_ch,
        .response_router = ctx.response_router,
        .exec_request_ch = ctx.exec_request_ch,
        .exec_response_ch = ctx.exec_response_ch,
    }, TickContext.tick, &wake_mutex, &wake_token);
}

const TickContext = struct {
    scheduler: *Scheduler,
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    exec_request_ch: *Channel(execution.Request),
    exec_response_ch: *Channel(execution.Response),

    fn tick(self: TickContext) ?i64 {
        while (self.exec_response_ch.try_receive()) |resp| {
            self.scheduler.execution_client.resolve(resp) catch |err| {
                std.log.warn("execution_client: failed to store execution result: {}", .{err});
            };
        }

        var drain_buf: [1024]query.Request = undefined;
        const n = self.request_ch.drain(&drain_buf);
        for (drain_buf[0..n]) |req| {
            const response = self.scheduler.handle_query(req) catch query.Response{ .request = req, .success = false };
            self.response_router.route(response);
        }

        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
        const now: i64 = @as(i64, @intCast(ts.sec)) * 1_000_000_000 + @as(i64, @intCast(ts.nsec));
        self.scheduler.tick(now) catch return null;

        self.scheduler.execution_client.drain_pending(self.exec_request_ch);
        if (self.scheduler.job_storage.to_execute.items.len > 0) return self.scheduler.job_storage.to_execute.items[0].execution;
        return null;
    }
};

fn run_processor(ctx: ProcessorContext) void {
    while (ctx.exec_request_ch.receive()) |req| {
        const resp = infrastructure_runner.execute(ctx.io, ctx.allocator, ctx.shell_config, req);
        ctx.exec_response_ch.send(resp) catch |err| {
            std.log.err("processor: response channel full, dropping response: {}", .{err});
            return;
        };
    }
}

test "config log levels map to matching standard log levels" {
    try std.testing.expectEqual(std.log.Level.info, log_level_to_std(.info).?);
    try std.testing.expectEqual(std.log.Level.warn, log_level_to_std(.warn).?);
    try std.testing.expectEqual(std.log.Level.debug, log_level_to_std(.debug).?);
}

test "config error level maps to standard err level" {
    try std.testing.expectEqual(std.log.Level.err, log_level_to_std(.@"error").?);
}

test "config trace level maps to standard debug level" {
    try std.testing.expectEqual(std.log.Level.debug, log_level_to_std(.trace).?);
}

test "config off level disables all logging" {
    try std.testing.expectEqual(@as(?std.log.Level, null), log_level_to_std(.off));
}

test "log output is written when message level meets configured threshold" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .info;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    log_fn_write(&w, .info, "test message", .{});
    try std.testing.expect(buf[0..w.end].len > 0);
}

test "log output uses bracket-level prefix and newline terminator" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .info;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    log_fn_write(&w, .info, "hello {s}", .{"world"});
    try std.testing.expectEqualStrings("[INFO] hello world\n", buf[0..w.end]);
}

test "log output formats error level as [ERROR] prefix" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .err;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    log_fn_write(&w, .err, "critical failure", .{});
    try std.testing.expectEqualStrings("[ERROR] critical failure\n", buf[0..w.end]);
}

test "log output is suppressed when message level is below configured threshold" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .warn;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    log_fn_write(&w, .info, "should not appear", .{});
    try std.testing.expectEqual(@as(usize, 0), buf[0..w.end].len);
}

test "startup log shows zero counts on empty database" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .info;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    log_fn_write(&w, .info, "loaded {d} jobs, {d} rules", .{ @as(usize, 0), @as(usize, 0) });
    try std.testing.expectEqualStrings("[INFO] loaded 0 jobs, 0 rules\n", buf[0..w.end]);
}

test "startup log shows actual job and rule counts" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .info;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    log_fn_write(&w, .info, "loaded {d} jobs, {d} rules", .{ @as(usize, 3), @as(usize, 2) });
    try std.testing.expectEqualStrings("[INFO] loaded 3 jobs, 2 rules\n", buf[0..w.end]);
}

test "startup log is suppressed when log level is off" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = null;
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    log_fn_write(&w, .info, "loaded {d} jobs, {d} rules", .{ @as(usize, 5), @as(usize, 3) });
    try std.testing.expectEqual(@as(usize, 0), buf[0..w.end].len);
}

test "processor thread routes execution request to response channel" {
    const allocator = std.testing.allocator;
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();

    const req = execution.Request{
        .identifier = 0xdeadbeef,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };
    try exec_req_ch.send(req);

    const thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
        .io = std.testing.io,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .shell_config = .{ .path = "/bin/sh", .args = &.{"-c"} },
    }});

    const resp = exec_resp_ch.receive() orelse unreachable;
    try std.testing.expectEqual(@as(u128, 0xdeadbeef), resp.identifier);
    try std.testing.expect(resp.success);

    exec_req_ch.close();
    thread.join();
}

test "run_dump returns FileNotFound for nonexistent logfile" {
    const allocator = std.testing.allocator;
    const options = interfaces_cli.DumpOptions{
        .logfile_path = "/nonexistent/path/ztick-test-logfile.bin",
        .format = .text,
        .compact = false,
        .follow = false,
    };
    try std.testing.expectError(interfaces_dump.DumpError.FileNotFound, interfaces_dump.run_dump(allocator, options, std.testing.io));
}

test "processor thread propagates shell failure to response channel" {
    const allocator = std.testing.allocator;
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();

    const req = execution.Request{
        .identifier = 0xcafe,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/false" } },
    };
    try exec_req_ch.send(req);

    const thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
        .io = std.testing.io,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .shell_config = .{ .path = "/bin/sh", .args = &.{"-c"} },
    }});

    const resp = exec_resp_ch.receive() orelse unreachable;
    try std.testing.expectEqual(@as(u128, 0xcafe), resp.identifier);
    try std.testing.expect(!resp.success);

    exec_req_ch.close();
    thread.join();
}

test "processor thread uses configured shell path from ProcessorContext" {
    const allocator = std.testing.allocator;
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();

    // /bin/false as the shell means any command will exit non-zero,
    // proving the custom path is forwarded rather than using the hardcoded default.
    const req = execution.Request{
        .identifier = 0xbabe,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };
    try exec_req_ch.send(req);

    const thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
        .io = std.testing.io,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .shell_config = .{ .path = "/bin/false", .args = &.{"-c"} },
    }});

    const resp = exec_resp_ch.receive() orelse unreachable;
    try std.testing.expectEqual(@as(u128, 0xbabe), resp.identifier);
    try std.testing.expect(!resp.success);

    exec_req_ch.close();
    thread.join();
}

test "processor thread executes direct runner request via ProcessorContext" {
    const allocator = std.testing.allocator;
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();

    const req = execution.Request{
        .identifier = 0xd1ec7,
        .job_identifier = "direct.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    try exec_req_ch.send(req);

    const thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
        .io = std.testing.io,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .shell_config = .{ .path = "/bin/sh", .args = &.{"-c"} },
    }});

    const resp = exec_resp_ch.receive() orelse unreachable;
    try std.testing.expectEqual(@as(u128, 0xd1ec7), resp.identifier);
    try std.testing.expect(resp.success);

    exec_req_ch.close();
    thread.join();
}

test "controller context tls_context is null when no TLS cert is configured" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var sig_fd = std.atomic.Value(std.posix.socket_t).init(-1);

    var active = std.atomic.Value(usize).init(0);
    const ctx = ControllerContext{
        .allocator = allocator,
        .io = std.testing.io,
        .address = "127.0.0.1:0",
        .request_ch = &req_ch,
        .response_router = &router,
        .running = &running,
        .tls_context = null,
        .token_store = null,
        .instruments = null,
        .active_connections = &active,
        .signal_listen_fd = &sig_fd,
    };
    try std.testing.expectEqual(@as(?*infrastructure_tls_context.TlsContext, null), ctx.tls_context);
    try std.testing.expectEqual(@as(?*application_token_store.TokenStore, null), ctx.token_store);
}

test "controller context token_store is non-null when auth file is configured" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var sig_fd = std.atomic.Value(std.posix.socket_t).init(-1);

    var store = application_token_store.TokenStore.init(allocator);
    defer store.deinit();

    var active = std.atomic.Value(usize).init(0);
    const ctx = ControllerContext{
        .allocator = allocator,
        .io = std.testing.io,
        .address = "127.0.0.1:0",
        .request_ch = &req_ch,
        .response_router = &router,
        .running = &running,
        .tls_context = null,
        .token_store = &store,
        .instruments = null,
        .active_connections = &active,
        .signal_listen_fd = &sig_fd,
    };
    try std.testing.expect(ctx.token_store != null);
}

test "controller context tls_context is non-null when cert and key are configured" {
    const allocator = std.testing.allocator;
    var tls_ctx = try infrastructure_tls_context.TlsContext.create(
        "test/fixtures/tls/cert.pem",
        "test/fixtures/tls/key.pem",
    );
    defer tls_ctx.deinit();

    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var sig_fd = std.atomic.Value(std.posix.socket_t).init(-1);

    var active = std.atomic.Value(usize).init(0);
    const ctx = ControllerContext{
        .allocator = allocator,
        .io = std.testing.io,
        .address = "127.0.0.1:0",
        .request_ch = &req_ch,
        .response_router = &router,
        .running = &running,
        .tls_context = &tls_ctx,
        .token_store = null,
        .instruments = null,
        .active_connections = &active,
        .signal_listen_fd = &sig_fd,
    };
    try std.testing.expect(ctx.tls_context != null);
}

test "DatabaseContext instruments field is null when telemetry is disabled" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(0);

    const ctx = DatabaseContext{
        .allocator = allocator,
        .io = std.testing.io,
        .framerate = 60,
        .backend = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .empty,
            .allocator = allocator,
        } },
        .compression_interval_ns = 0,
        .running = &running,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .instruments = null,
        .startup_ns = 0,
        .active_connections = &ac,
        .auth_enabled = false,
        .tls_enabled = false,
    };
    try std.testing.expectEqual(@as(?infrastructure_telemetry.Instruments, null), ctx.instruments);
}

test "DatabaseContext instruments field holds Instruments when telemetry is enabled" {
    const allocator = std.testing.allocator;

    const otel = @import("opentelemetry");
    const meter_provider = try otel.metrics.MeterProvider.init(allocator, std.testing.io);
    defer meter_provider.shutdown();
    const tracer_provider = try otel.trace.TracerProvider.init(
        allocator,
        std.testing.io,
        otel.trace.IDGenerator{ .Random = otel.trace.RandomIDGenerator.init((std.Random.IoSource{ .io = std.testing.io }).interface()) },
    );
    defer tracer_provider.shutdown();

    const instruments = try infrastructure_telemetry.createInstruments(meter_provider, tracer_provider);

    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(0);

    const ctx = DatabaseContext{
        .allocator = allocator,
        .io = std.testing.io,
        .framerate = 60,
        .backend = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .empty,
            .allocator = allocator,
        } },
        .compression_interval_ns = 0,
        .running = &running,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .instruments = instruments,
        .startup_ns = 0,
        .active_connections = &ac,
        .auth_enabled = false,
        .tls_enabled = false,
    };
    try std.testing.expect(ctx.instruments != null);
}

test "tick with instrumented scheduler processes SET query and routes success response" {
    const allocator = std.testing.allocator;

    const otel = @import("opentelemetry");
    const meter_provider = try otel.metrics.MeterProvider.init(allocator, std.testing.io);
    defer meter_provider.shutdown();
    const tracer_provider = try otel.trace.TracerProvider.init(
        allocator,
        std.testing.io,
        otel.trace.IDGenerator{ .Random = otel.trace.RandomIDGenerator.init((std.Random.IoSource{ .io = std.testing.io }).interface()) },
    );
    defer tracer_provider.shutdown();

    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var resp_ch = try Channel(query.Response).init(allocator, std.testing.io, 4);
    defer resp_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();

    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    try router.register(1, &resp_ch);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.set_instruments(try infrastructure_telemetry.createInstruments(meter_provider, tracer_provider));

    const req = query.Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1_000_000_000 } },
    };
    try req_ch.send(req);

    const ctx = TickContext{
        .scheduler = &scheduler,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
    };
    _ = ctx.tick();

    const resp = resp_ch.try_receive();
    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.success);
}

test "DatabaseContext carries persistence backend and compression interval" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ac = std.atomic.Value(usize).init(0);

    const logfile_ctx = DatabaseContext{
        .allocator = allocator,
        .io = std.testing.io,
        .framerate = 60,
        .backend = persistence_backend.PersistenceBackend{ .logfile = .{
            .logfile_path = "ztick.log",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
            .io = std.testing.io,
        } },
        .compression_interval_ns = 3600 * std.time.ns_per_s,
        .running = &running,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .instruments = null,
        .startup_ns = 0,
        .active_connections = &ac,
        .auth_enabled = false,
        .tls_enabled = false,
    };
    try std.testing.expect(logfile_ctx.backend == .logfile);
    try std.testing.expectEqual(@as(u64, 3600 * std.time.ns_per_s), logfile_ctx.compression_interval_ns);

    const memory_ctx = DatabaseContext{
        .allocator = allocator,
        .io = std.testing.io,
        .framerate = 60,
        .backend = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .empty,
            .allocator = allocator,
        } },
        .compression_interval_ns = 0,
        .running = &running,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .instruments = null,
        .startup_ns = 0,
        .active_connections = &ac,
        .auth_enabled = false,
        .tls_enabled = false,
    };
    try std.testing.expect(memory_ctx.backend == .memory);
}

test "DatabaseContext carries startup_ns for STAT uptime calculation" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(0);

    const boot_ns: i128 = 1_700_000_000_000_000_000;
    const ctx = DatabaseContext{
        .allocator = allocator,
        .io = std.testing.io,
        .framerate = 512,
        .backend = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .empty,
            .allocator = allocator,
        } },
        .compression_interval_ns = 0,
        .running = &running,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .instruments = null,
        .startup_ns = boot_ns,
        .active_connections = &ac,
        .auth_enabled = false,
        .tls_enabled = false,
    };
    try std.testing.expectEqual(boot_ns, ctx.startup_ns);
    try std.testing.expectEqual(@as(u16, 512), ctx.framerate);
}

test "DatabaseContext carries active_connections pointer for STAT connection count" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(3);

    const ctx = DatabaseContext{
        .allocator = allocator,
        .io = std.testing.io,
        .framerate = 60,
        .backend = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .empty,
            .allocator = allocator,
        } },
        .compression_interval_ns = 0,
        .running = &running,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .instruments = null,
        .startup_ns = 0,
        .active_connections = &ac,
        .auth_enabled = false,
        .tls_enabled = false,
    };
    try std.testing.expectEqual(@as(usize, 3), ctx.active_connections.load(.acquire));
}

test "DatabaseContext carries auth_enabled and tls_enabled flags for STAT reporting" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(0);

    const ctx = DatabaseContext{
        .allocator = allocator,
        .io = std.testing.io,
        .framerate = 60,
        .backend = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .empty,
            .allocator = allocator,
        } },
        .compression_interval_ns = 0,
        .running = &running,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
        .instruments = null,
        .startup_ns = 0,
        .active_connections = &ac,
        .auth_enabled = true,
        .tls_enabled = true,
    };
    try std.testing.expect(ctx.auth_enabled);
    try std.testing.expect(ctx.tls_enabled);
}

test "tick with memory backend persists SET mutation to backend entries" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var resp_ch = try Channel(query.Response).init(allocator, std.testing.io, 4);
    defer resp_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    try router.register(1, &resp_ch);

    const backend_state = BackendState.init(persistence_backend.PersistenceBackend{ .memory = .{
        .entries = .empty,
        .allocator = allocator,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;

    const req = query.Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1_000_000_000 } },
    };
    try req_ch.send(req);

    const ctx = TickContext{
        .scheduler = &scheduler,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
    };
    _ = ctx.tick();

    const resp = resp_ch.try_receive();
    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.success);
    try std.testing.expectEqual(@as(usize, 1), scheduler.persistence.?.backend.memory.entries.items.len);
}

test "tick processes query request and routes response" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var resp_ch = try Channel(query.Response).init(allocator, std.testing.io, 4);
    defer resp_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();

    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();

    try router.register(1, &resp_ch);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const req = query.Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1_000_000_000 } },
    };
    try req_ch.send(req);

    const ctx = TickContext{
        .scheduler = &scheduler,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
    };
    _ = ctx.tick();

    const resp = resp_ch.try_receive();
    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.success);
}

test "tick returns null when no jobs are scheduled" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const ctx = TickContext{
        .scheduler = &scheduler,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
    };

    const result = ctx.tick();
    try std.testing.expectEqual(@as(?i64, null), result);
}

test "tick returns earliest job execution time after drain processes SET request" {
    const allocator = std.testing.allocator;
    const future_ns: i64 = 9_000_000_000_000_000_000;

    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 4);
    defer req_ch.deinit();
    var resp_ch = try Channel(query.Response).init(allocator, std.testing.io, 4);
    defer resp_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    try router.register(1, &resp_ch);
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const req = query.Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = future_ns } },
    };
    try req_ch.send(req);

    const ctx = TickContext{
        .scheduler = &scheduler,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
    };

    const result = ctx.tick();
    try std.testing.expectEqual(@as(?i64, future_ns), result);
}

test "tick drains three concurrent SET requests in a single call and routes all responses" {
    const allocator = std.testing.allocator;

    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 8);
    defer req_ch.deinit();
    var resp_ch = try Channel(query.Response).init(allocator, std.testing.io, 8);
    defer resp_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    try router.register(1, &resp_ch);
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try req_ch.send(query.Request{ .client = 1, .identifier = "r1", .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1_000_000_000 } } });
    try req_ch.send(query.Request{ .client = 1, .identifier = "r2", .instruction = .{ .set = .{ .identifier = "job.2", .execution = 2_000_000_000 } } });
    try req_ch.send(query.Request{ .client = 1, .identifier = "r3", .instruction = .{ .set = .{ .identifier = "job.3", .execution = 3_000_000_000 } } });

    const ctx = TickContext{
        .scheduler = &scheduler,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
    };
    _ = ctx.tick();

    try std.testing.expect(resp_ch.try_receive() != null);
    try std.testing.expect(resp_ch.try_receive() != null);
    try std.testing.expect(resp_ch.try_receive() != null);
}

test "tick returns earliest of two jobs when both are future-scheduled" {
    const allocator = std.testing.allocator;
    const near_ns: i64 = 2_000_000_000_000_000_000;
    const far_ns: i64 = 9_000_000_000_000_000_000;

    var req_ch = try Channel(query.Request).init(allocator, std.testing.io, 8);
    defer req_ch.deinit();
    var resp_ch = try Channel(query.Response).init(allocator, std.testing.io, 8);
    defer resp_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, std.testing.io, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, std.testing.io, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator, std.testing.io);
    defer router.deinit();
    try router.register(1, &resp_ch);
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try req_ch.send(query.Request{ .client = 1, .identifier = "r1", .instruction = .{ .set = .{ .identifier = "job.far", .execution = far_ns } } });
    try req_ch.send(query.Request{ .client = 1, .identifier = "r2", .instruction = .{ .set = .{ .identifier = "job.near", .execution = near_ns } } });

    const ctx = TickContext{
        .scheduler = &scheduler,
        .request_ch = &req_ch,
        .response_router = &router,
        .exec_request_ch = &exec_req_ch,
        .exec_response_ch = &exec_resp_ch,
    };

    const result = ctx.tick();
    try std.testing.expectEqual(@as(?i64, near_ns), result);
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    while (args_iter.next()) |arg| {
        try argv.append(allocator, arg);
    }

    const command = try interfaces_cli.parse(&init, allocator, argv.items);

    if (command == .dump) {
        defer allocator.free(command.dump.options.logfile_path);
        interfaces_dump.run_dump(allocator, command.dump.options, init.io) catch |err| switch (err) {
            error.FileNotFound => {
                var ebuf: [256]u8 = undefined;
                var ew = std.Io.File.stderr().writer(init.io, &ebuf);
                ew.interface.print("error: file not found: {s}\n", .{command.dump.options.logfile_path}) catch {};
                ew.interface.flush() catch {};
                std.process.exit(1);
            },
            error.PermissionDenied => {
                var ebuf: [256]u8 = undefined;
                var ew = std.Io.File.stderr().writer(init.io, &ebuf);
                ew.interface.print("error: permission denied: {s}\n", .{command.dump.options.logfile_path}) catch {};
                ew.interface.flush() catch {};
                std.process.exit(1);
            },
            else => return err,
        };
        return;
    }

    const config_path = command.server.config_path;
    defer if (config_path) |p| allocator.free(p);
    const cfg = try interfaces_config.load(allocator, config_path, init.io);
    defer cfg.deinit(allocator);

    runtime_log_level = log_level_to_std(cfg.log_level);
    std.log.info("config: {s}", .{config_path orelse "default"});
    std.log.info("log level: {s}", .{@tagName(cfg.log_level)});
    std.log.info("listening on {s}", .{cfg.controller_listen});

    const telemetry_providers = try infrastructure_telemetry.setup(allocator, cfg.telemetry, init.environ_map, init.io);
    defer if (telemetry_providers) |p| p.shutdown();

    if (telemetry_providers) |p| {
        const otel = @import("opentelemetry");
        try p.tracer_provider.addSpanProcessor(p.trace_processor.asSpanProcessor());
        try p.logger_provider.addLogRecordProcessor(p.log_processor.asLogRecordProcessor());
        try otel.logs.std_log_bridge.configure(.{
            .provider = p.logger_provider,
            .also_log_to_stderr = true,
        });
    }

    const telemetry_instruments: ?infrastructure_telemetry.Instruments = if (telemetry_providers) |p|
        try infrastructure_telemetry.createInstruments(p.meter_provider, p.tracer_provider)
    else
        null;

    const startup_ns: i128 = std.Io.Timestamp.now(init.io, .awake).nanoseconds;
    var active_connections = std.atomic.Value(usize).init(0);

    const cwd = std.Io.Dir.cwd();

    var query_request_ch = try Channel(query.Request).init(allocator, init.io, 1024);
    defer query_request_ch.deinit();

    var exec_request_ch = try Channel(execution.Request).init(allocator, init.io, 64);
    defer exec_request_ch.deinit();

    var exec_response_ch = try Channel(execution.Response).init(allocator, init.io, 64);
    defer exec_response_ch.deinit();

    var response_router = ResponseRouter.init(allocator, init.io);
    defer response_router.deinit();

    var running = std.atomic.Value(bool).init(true);

    global_running = &running;
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = signal_handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

    var tls_ctx: ?infrastructure_tls_context.TlsContext = null;
    if (cfg.controller_tls_cert) |cert| {
        const key = cfg.controller_tls_key.?;
        tls_ctx = try infrastructure_tls_context.TlsContext.create(cert, key);
    }
    defer if (tls_ctx) |*ctx| ctx.deinit();

    var token_store: ?application_token_store.TokenStore = null;
    var auth_tokens: ?[]domain.auth.Token = null;
    if (cfg.controller_auth_file) |auth_file| {
        auth_tokens = try infrastructure_auth.load(init.io, allocator, auth_file);
        var store = application_token_store.TokenStore.init(allocator);
        try store.load(auth_tokens.?);
        token_store = store;
    }
    defer if (auth_tokens) |tokens| {
        for (tokens) |t| {
            allocator.free(t.name);
            allocator.free(t.secret);
            allocator.free(t.namespace);
        }
        allocator.free(tokens);
    };
    defer if (token_store) |*store| store.deinit();

    const controller_thread = try std.Thread.spawn(.{}, run_controller, .{ControllerContext{
        .allocator = allocator,
        .io = init.io,
        .address = cfg.controller_listen,
        .request_ch = &query_request_ch,
        .response_router = &response_router,
        .running = &running,
        .tls_context = if (tls_ctx) |*ctx| ctx else null,
        .token_store = if (token_store) |*store| store else null,
        .instruments = telemetry_instruments,
        .active_connections = &active_connections,
        .signal_listen_fd = &global_listen_fd,
    }});
    // If any later spawn fails, signal running=false so the controller exits its accept loop.
    errdefer {
        running.store(false, .release);
        controller_thread.join();
    }

    const http_thread: ?std.Thread = if (cfg.http_listen) |http_addr| blk: {
        std.log.info("HTTP listening on {s}", .{http_addr});
        const ht = try std.Thread.spawn(.{}, run_http_controller, .{HttpControllerContext{
            .allocator = allocator,
            .io = init.io,
            .address = http_addr,
            .request_ch = &query_request_ch,
            .response_router = &response_router,
            .running = &running,
            .bearer_token = cfg.http_bearer_token,
            .signal_listen_fd = &global_http_listen_fd,
        }});
        break :blk ht;
    } else null;
    // If any later spawn fails, join the http thread (running already false from above errdefer).
    errdefer if (http_thread) |ht| ht.join();

    const backend: persistence_backend.PersistenceBackend = switch (cfg.database_persistence) {
        .logfile => .{ .logfile = .{
            .logfile_path = cfg.database_logfile_path,
            .logfile_dir = cwd,
            .load_arena = null,
            .fsync_on_persist = cfg.database_fsync_on_persist,
            .io = init.io,
        } },
        .memory => .{ .memory = .{
            .entries = .empty,
            .allocator = allocator,
        } },
    };

    const database_thread = try std.Thread.spawn(.{}, run_database, .{DatabaseContext{
        .allocator = allocator,
        .io = init.io,
        .framerate = cfg.database_framerate,
        .backend = backend,
        .compression_interval_ns = @as(u64, cfg.database_compression_interval) * std.time.ns_per_s,
        .running = &running,
        .request_ch = &query_request_ch,
        .response_router = &response_router,
        .exec_request_ch = &exec_request_ch,
        .exec_response_ch = &exec_response_ch,
        .instruments = telemetry_instruments,
        .startup_ns = startup_ns,
        .active_connections = &active_connections,
        .auth_enabled = cfg.controller_auth_file != null,
        .tls_enabled = cfg.controller_tls_cert != null,
    }});
    // If the processor spawn fails, close the request channel so the database exits its tick loop.
    errdefer {
        query_request_ch.close();
        database_thread.join();
    }

    const processor_thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
        .io = init.io,
        .exec_request_ch = &exec_request_ch,
        .exec_response_ch = &exec_response_ch,
        .shell_config = cfg.shell,
    }});

    controller_thread.join();

    running.store(false, .release);

    if (http_thread) |ht| ht.join();

    query_request_ch.close();

    database_thread.join();

    exec_request_ch.close();
    processor_thread.join();
}
