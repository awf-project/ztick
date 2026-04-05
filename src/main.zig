const std = @import("std");
const domain_job = @import("domain/job.zig");
const domain_rule = @import("domain/rule.zig");
const domain_runner = @import("domain/runner.zig");
const domain_instruction = @import("domain/instruction.zig");
const domain_query = @import("domain/query.zig");
const domain_execution = @import("domain/execution.zig");
const persistence_encoder = @import("infrastructure/persistence/encoder.zig");
const persistence_logfile = @import("infrastructure/persistence/logfile.zig");
const persistence_backend = @import("infrastructure/persistence/backend.zig");
const protocol_parser = @import("infrastructure/protocol/parser.zig");
const application_job_storage = @import("application/job_storage.zig");
const application_rule_storage = @import("application/rule_storage.zig");
const application_query_handler = @import("application/query_handler.zig");
const application_execution_client = @import("application/execution_client.zig");
const application_scheduler = @import("application/scheduler.zig");
const infrastructure_channel = @import("infrastructure/channel.zig");
const infrastructure_clock = @import("infrastructure/clock.zig");
const infrastructure_shell_runner = @import("infrastructure/shell_runner.zig");
const infrastructure_tcp_server = @import("infrastructure/tcp_server.zig");
const infrastructure_http = @import("infrastructure/http.zig");
const infrastructure_tls_context = @import("infrastructure/tls_context.zig");
const infrastructure_telemetry = @import("infrastructure/telemetry.zig");
const infrastructure_persistence_background = @import("infrastructure/persistence/background.zig");
const interfaces_config = @import("interfaces/config.zig");
const interfaces_cli = @import("interfaces/cli.zig");
const interfaces_dump = @import("interfaces/dump.zig");

var runtime_log_level: ?std.log.Level = null;

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
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    log_fn_write(std.fs.File.stderr().deprecatedWriter(), level, format, args);
}

const Channel = infrastructure_channel.Channel;
const TcpServer = infrastructure_tcp_server.TcpServer;
const Scheduler = application_scheduler.Scheduler;
const ShellRunner = infrastructure_shell_runner.ShellRunner;
const Clock = infrastructure_clock.Clock;
const query = domain_query;
const execution = domain_execution;

test {
    _ = domain_job;
    _ = domain_rule;
    _ = domain_runner;
    _ = domain_instruction;
    _ = domain_query;
    _ = domain_execution;
    _ = persistence_encoder;
    _ = persistence_logfile;
    _ = persistence_backend;
    _ = protocol_parser;
    _ = application_job_storage;
    _ = application_rule_storage;
    _ = application_query_handler;
    _ = application_execution_client;
    _ = application_scheduler;
    _ = infrastructure_channel;
    _ = infrastructure_clock;
    _ = infrastructure_shell_runner;
    _ = infrastructure_tcp_server;
    _ = infrastructure_http;
    _ = infrastructure_tls_context;
    _ = infrastructure_telemetry;
    _ = infrastructure_persistence_background;
    _ = interfaces_config;
    _ = interfaces_cli;
    _ = interfaces_dump;
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
    address: []const u8,
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    running: *std.atomic.Value(bool),
    tls_context: ?*infrastructure_tls_context.TlsContext,
    instruments: ?infrastructure_telemetry.Instruments,
    active_connections: *std.atomic.Value(usize),
};

const DatabaseContext = struct {
    allocator: std.mem.Allocator,
    framerate: u16,
    persistence: persistence_backend.PersistenceBackend,
    compression_interval_ns: i64,
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
    exec_request_ch: *Channel(execution.Request),
    exec_response_ch: *Channel(execution.Response),
    shell_config: interfaces_config.ShellConfig,
};

const HttpControllerContext = struct {
    allocator: std.mem.Allocator,
    address: []const u8,
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    running: *std.atomic.Value(bool),
    bearer_token: ?[]const u8,
};

fn run_http_controller(ctx: HttpControllerContext) void {
    var server = infrastructure_http.HttpServer.init(
        ctx.allocator,
        ctx.address,
        ctx.running,
        ctx.request_ch,
        ctx.response_router,
        ctx.bearer_token,
    );
    server.start() catch |err| {
        std.log.err("http controller: start failed: {}", .{err});
    };
}

fn run_controller(ctx: ControllerContext) void {
    var server = TcpServer.init(ctx.allocator, ctx.address, ctx.running, ctx.tls_context, ctx.active_connections);
    if (ctx.instruments) |instr| server.setInstruments(instr);
    defer server.deinit();
    server.start(ctx.request_ch, ctx.response_router) catch |err| {
        std.log.err("controller: start failed: {}", .{err});
        return;
    };
    server.join_all();
}

pub fn compress_startup_leftover(allocator: std.mem.Allocator, backend: persistence_backend.PersistenceBackend) void {
    const lf = switch (backend) {
        .logfile => |lf| lf,
        .memory => return,
    };
    const dir = lf.logfile_dir orelse return;
    const filenames = infrastructure_persistence_background.Filenames{};
    const f = dir.openFile(filenames.source, .{}) catch return;
    f.close();
    infrastructure_persistence_background.compress(allocator, dir, filenames) catch {
        std.log.warn("startup: leftover .to_compress compression failed", .{});
    };
}

fn run_database(ctx: DatabaseContext) void {
    var scheduler = Scheduler.init(ctx.allocator);
    scheduler.persistence = ctx.persistence;
    scheduler.compression_interval_ns = ctx.compression_interval_ns;
    if (ctx.instruments) |instr| scheduler.setInstruments(instr);
    scheduler.setStatContext(ctx.startup_ns, ctx.active_connections, ctx.auth_enabled, ctx.tls_enabled, ctx.framerate);
    defer scheduler.deinit();

    scheduler.load(ctx.allocator) catch |err| {
        std.log.warn("database: load failed: {}", .{err});
    };

    compress_startup_leftover(ctx.allocator, ctx.persistence);
    std.log.info("loaded {d} jobs, {d} rules", .{
        scheduler.job_storage.jobs.count(),
        scheduler.rule_storage.rules.count(),
    });

    const clock = Clock.init(ctx.framerate, ctx.running);
    clock.start(TickContext{
        .scheduler = &scheduler,
        .request_ch = ctx.request_ch,
        .response_router = ctx.response_router,
        .exec_request_ch = ctx.exec_request_ch,
        .exec_response_ch = ctx.exec_response_ch,
    }, TickContext.tick);
}

const TickContext = struct {
    scheduler: *Scheduler,
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    exec_request_ch: *Channel(execution.Request),
    exec_response_ch: *Channel(execution.Response),

    fn tick(self: TickContext) void {
        while (self.exec_response_ch.try_receive()) |resp| {
            self.scheduler.execution_client.resolve(resp);
        }

        while (self.request_ch.try_receive()) |req| {
            const response = self.scheduler.handle_query(req) catch query.Response{ .request = req, .success = false };
            self.response_router.route(response);
        }

        const now: i64 = @intCast(std.time.nanoTimestamp());
        self.scheduler.tick(now) catch return;

        self.scheduler.execution_client.drain_pending(self.exec_request_ch);
    }
};

fn run_processor(ctx: ProcessorContext) void {
    while (ctx.exec_request_ch.receive()) |req| {
        const resp = ShellRunner.execute(ctx.allocator, ctx.shell_config, req) catch execution.Response{
            .identifier = req.identifier,
            .success = false,
        };
        ctx.exec_response_ch.send(resp) catch return;
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
    var fbs = std.io.fixedBufferStream(&buf);
    log_fn_write(fbs.writer(), .info, "test message", .{});
    try std.testing.expect(fbs.getWritten().len > 0);
}

test "log output uses bracket-level prefix and newline terminator" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .info;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    log_fn_write(fbs.writer(), .info, "hello {s}", .{"world"});
    try std.testing.expectEqualStrings("[INFO] hello world\n", fbs.getWritten());
}

test "log output formats error level as [ERROR] prefix" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .err;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    log_fn_write(fbs.writer(), .err, "critical failure", .{});
    try std.testing.expectEqualStrings("[ERROR] critical failure\n", fbs.getWritten());
}

test "log output is suppressed when message level is below configured threshold" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .warn;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    log_fn_write(fbs.writer(), .info, "should not appear", .{});
    try std.testing.expectEqual(@as(usize, 0), fbs.getWritten().len);
}

test "startup log shows zero counts on empty database" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .info;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    log_fn_write(fbs.writer(), .info, "loaded {d} jobs, {d} rules", .{ @as(usize, 0), @as(usize, 0) });
    try std.testing.expectEqualStrings("[INFO] loaded 0 jobs, 0 rules\n", fbs.getWritten());
}

test "startup log shows actual job and rule counts" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = .info;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    log_fn_write(fbs.writer(), .info, "loaded {d} jobs, {d} rules", .{ @as(usize, 3), @as(usize, 2) });
    try std.testing.expectEqualStrings("[INFO] loaded 3 jobs, 2 rules\n", fbs.getWritten());
}

test "startup log is suppressed when log level is off" {
    const saved = runtime_log_level;
    defer runtime_log_level = saved;
    runtime_log_level = null;
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    log_fn_write(fbs.writer(), .info, "loaded {d} jobs, {d} rules", .{ @as(usize, 5), @as(usize, 3) });
    try std.testing.expectEqual(@as(usize, 0), fbs.getWritten().len);
}

test "processor thread routes execution request to response channel" {
    const allocator = std.testing.allocator;
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();

    const req = execution.Request{
        .identifier = 0xdeadbeef,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };
    try exec_req_ch.send(req);

    const thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
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
    try std.testing.expectError(interfaces_dump.DumpError.FileNotFound, interfaces_dump.run_dump(allocator, options));
}

test "processor thread propagates shell failure to response channel" {
    const allocator = std.testing.allocator;
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();

    const req = execution.Request{
        .identifier = 0xcafe,
        .job_identifier = "test.job",
        .runner = .{ .shell = .{ .command = "/bin/false" } },
    };
    try exec_req_ch.send(req);

    const thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
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
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
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
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();

    const req = execution.Request{
        .identifier = 0xd1ec7,
        .job_identifier = "direct.job",
        .runner = .{ .direct = .{ .executable = "/bin/true", .args = &.{} } },
    };
    try exec_req_ch.send(req);

    const thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
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
    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);

    var active = std.atomic.Value(usize).init(0);
    const ctx = ControllerContext{
        .allocator = allocator,
        .address = "127.0.0.1:0",
        .request_ch = &req_ch,
        .response_router = &router,
        .running = &running,
        .tls_context = null,
        .instruments = null,
        .active_connections = &active,
    };
    try std.testing.expectEqual(@as(?*infrastructure_tls_context.TlsContext, null), ctx.tls_context);
}

test "controller context tls_context is non-null when cert and key are configured" {
    const allocator = std.testing.allocator;
    var tls_ctx = try infrastructure_tls_context.TlsContext.create(
        "test/fixtures/tls/cert.pem",
        "test/fixtures/tls/key.pem",
    );
    defer tls_ctx.deinit();

    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);

    var active = std.atomic.Value(usize).init(0);
    const ctx = ControllerContext{
        .allocator = allocator,
        .address = "127.0.0.1:0",
        .request_ch = &req_ch,
        .response_router = &router,
        .running = &running,
        .tls_context = &tls_ctx,
        .instruments = null,
        .active_connections = &active,
    };
    try std.testing.expect(ctx.tls_context != null);
}

test "DatabaseContext instruments field is null when telemetry is disabled" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(0);

    const ctx = DatabaseContext{
        .allocator = allocator,
        .framerate = 60,
        .persistence = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .{},
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
    const meter_provider = try otel.metrics.MeterProvider.init(allocator);
    defer meter_provider.shutdown();
    const tracer_provider = try otel.trace.TracerProvider.init(
        allocator,
        otel.trace.IDGenerator{ .Random = otel.trace.RandomIDGenerator.init(std.crypto.random) },
    );
    defer tracer_provider.shutdown();

    const instruments = try infrastructure_telemetry.createInstruments(meter_provider, tracer_provider);

    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(0);

    const ctx = DatabaseContext{
        .allocator = allocator,
        .framerate = 60,
        .persistence = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .{},
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
    const meter_provider = try otel.metrics.MeterProvider.init(allocator);
    defer meter_provider.shutdown();
    const tracer_provider = try otel.trace.TracerProvider.init(
        allocator,
        otel.trace.IDGenerator{ .Random = otel.trace.RandomIDGenerator.init(std.crypto.random) },
    );
    defer tracer_provider.shutdown();

    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var resp_ch = try Channel(query.Response).init(allocator, 4);
    defer resp_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();

    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    router.register(1, &resp_ch);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.setInstruments(try infrastructure_telemetry.createInstruments(meter_provider, tracer_provider));

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
    ctx.tick();

    const resp = resp_ch.try_receive();
    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.success);
}

test "DatabaseContext carries persistence backend and compression interval" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ac = std.atomic.Value(usize).init(0);

    const logfile_ctx = DatabaseContext{
        .allocator = allocator,
        .framerate = 60,
        .persistence = persistence_backend.PersistenceBackend{ .logfile = .{
            .logfile_path = "ztick.log",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
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
    try std.testing.expect(logfile_ctx.persistence == .logfile);
    try std.testing.expectEqual(@as(i64, 3600 * std.time.ns_per_s), logfile_ctx.compression_interval_ns);

    const memory_ctx = DatabaseContext{
        .allocator = allocator,
        .framerate = 60,
        .persistence = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .{},
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
    try std.testing.expect(memory_ctx.persistence == .memory);
}

test "DatabaseContext carries startup_ns for STAT uptime calculation" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(0);

    const boot_ns: i128 = 1_700_000_000_000_000_000;
    const ctx = DatabaseContext{
        .allocator = allocator,
        .framerate = 512,
        .persistence = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .{},
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
    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(3);

    const ctx = DatabaseContext{
        .allocator = allocator,
        .framerate = 60,
        .persistence = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .{},
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
    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    var running = std.atomic.Value(bool).init(false);
    var ac = std.atomic.Value(usize).init(0);

    const ctx = DatabaseContext{
        .allocator = allocator,
        .framerate = 60,
        .persistence = persistence_backend.PersistenceBackend{ .memory = .{
            .entries = .{},
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
    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var resp_ch = try Channel(query.Response).init(allocator, 4);
    defer resp_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();
    var router = ResponseRouter.init(allocator);
    defer router.deinit();
    router.register(1, &resp_ch);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = persistence_backend.PersistenceBackend{ .memory = .{
        .entries = .{},
        .allocator = allocator,
    } };

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
    ctx.tick();

    const resp = resp_ch.try_receive();
    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.success);
    try std.testing.expectEqual(@as(usize, 1), scheduler.persistence.?.memory.entries.items.len);
}

test "tick processes query request and routes response" {
    const allocator = std.testing.allocator;
    var req_ch = try Channel(query.Request).init(allocator, 4);
    defer req_ch.deinit();
    var resp_ch = try Channel(query.Response).init(allocator, 4);
    defer resp_ch.deinit();
    var exec_req_ch = try Channel(execution.Request).init(allocator, 4);
    defer exec_req_ch.deinit();
    var exec_resp_ch = try Channel(execution.Response).init(allocator, 4);
    defer exec_resp_ch.deinit();

    var router = ResponseRouter.init(allocator);
    defer router.deinit();

    router.register(1, &resp_ch);

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
    ctx.tick();

    const resp = resp_ch.try_receive();
    try std.testing.expect(resp != null);
    try std.testing.expect(resp.?.success);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const command = try interfaces_cli.parse(allocator);

    if (command == .dump) {
        defer allocator.free(command.dump.options.logfile_path);
        interfaces_dump.run_dump(allocator, command.dump.options) catch |err| switch (err) {
            error.FileNotFound => {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("error: file not found: {s}\n", .{command.dump.options.logfile_path}) catch {};
                std.process.exit(1);
            },
            error.PermissionDenied => {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("error: permission denied: {s}\n", .{command.dump.options.logfile_path}) catch {};
                std.process.exit(1);
            },
            else => return err,
        };
        return;
    }

    const config_path = command.server.config_path;
    defer if (config_path) |p| allocator.free(p);
    const cfg = try interfaces_config.load(allocator, config_path);
    defer cfg.deinit(allocator);

    runtime_log_level = log_level_to_std(cfg.log_level);
    std.log.info("config: {s}", .{config_path orelse "default"});
    std.log.info("log level: {s}", .{@tagName(cfg.log_level)});
    std.log.info("listening on {s}", .{cfg.controller_listen});

    const telemetry_providers = try infrastructure_telemetry.setup(allocator, cfg.telemetry);
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

    const startup_ns = std.time.nanoTimestamp();
    var active_connections = std.atomic.Value(usize).init(0);

    const cwd = std.fs.cwd();

    var query_request_ch = try Channel(query.Request).init(allocator, 64);
    defer query_request_ch.deinit();

    var exec_request_ch = try Channel(execution.Request).init(allocator, 64);
    defer exec_request_ch.deinit();

    var exec_response_ch = try Channel(execution.Response).init(allocator, 64);
    defer exec_response_ch.deinit();

    var response_router = ResponseRouter.init(allocator);
    defer response_router.deinit();

    var running = std.atomic.Value(bool).init(true);

    var tls_ctx: ?infrastructure_tls_context.TlsContext = null;
    if (cfg.controller_tls_cert) |cert| {
        const key = cfg.controller_tls_key.?;
        tls_ctx = try infrastructure_tls_context.TlsContext.create(cert, key);
    }
    defer if (tls_ctx) |*ctx| ctx.deinit();

    const controller_thread = try std.Thread.spawn(.{}, run_controller, .{ControllerContext{
        .allocator = allocator,
        .address = cfg.controller_listen,
        .request_ch = &query_request_ch,
        .response_router = &response_router,
        .running = &running,
        .tls_context = if (tls_ctx) |*ctx| ctx else null,
        .instruments = telemetry_instruments,
        .active_connections = &active_connections,
    }});

    const http_thread: ?std.Thread = if (cfg.http_listen) |http_addr| blk: {
        std.log.info("HTTP listening on {s}", .{http_addr});
        break :blk try std.Thread.spawn(.{}, run_http_controller, .{HttpControllerContext{
            .allocator = allocator,
            .address = http_addr,
            .request_ch = &query_request_ch,
            .response_router = &response_router,
            .running = &running,
            .bearer_token = null,
        }});
    } else null;

    const backend: persistence_backend.PersistenceBackend = switch (cfg.database_persistence) {
        .logfile => .{ .logfile = .{
            .logfile_path = cfg.database_logfile_path,
            .logfile_dir = cwd,
            .load_arena = null,
            .fsync_on_persist = cfg.database_fsync_on_persist,
        } },
        .memory => .{ .memory = .{
            .entries = .{},
            .allocator = allocator,
        } },
    };

    const database_thread = try std.Thread.spawn(.{}, run_database, .{DatabaseContext{
        .allocator = allocator,
        .framerate = cfg.database_framerate,
        .persistence = backend,
        .compression_interval_ns = @as(i64, cfg.database_compression_interval) * std.time.ns_per_s,
        .running = &running,
        .request_ch = &query_request_ch,
        .response_router = &response_router,
        .exec_request_ch = &exec_request_ch,
        .exec_response_ch = &exec_response_ch,
        .instruments = telemetry_instruments,
        .startup_ns = startup_ns,
        .active_connections = &active_connections,
        .auth_enabled = false,
        .tls_enabled = cfg.controller_tls_cert != null,
    }});

    const processor_thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
        .exec_request_ch = &exec_request_ch,
        .exec_response_ch = &exec_response_ch,
        .shell_config = cfg.shell,
    }});

    controller_thread.join();

    if (http_thread) |ht| ht.join();

    running.store(false, .release);
    query_request_ch.close();

    database_thread.join();

    exec_request_ch.close();
    processor_thread.join();
}
