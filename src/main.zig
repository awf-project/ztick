const std = @import("std");
const domain_job = @import("domain/job.zig");
const domain_rule = @import("domain/rule.zig");
const domain_runner = @import("domain/runner.zig");
const domain_instruction = @import("domain/instruction.zig");
const domain_query = @import("domain/query.zig");
const domain_execution = @import("domain/execution.zig");
const persistence_encoder = @import("infrastructure/persistence/encoder.zig");
const persistence_logfile = @import("infrastructure/persistence/logfile.zig");
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
const infrastructure_persistence_background = @import("infrastructure/persistence/background.zig");
const interfaces_config = @import("interfaces/config.zig");
const interfaces_cli = @import("interfaces/cli.zig");

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
    _ = infrastructure_persistence_background;
    _ = interfaces_config;
    _ = interfaces_cli;
}

const ResponseRouter = infrastructure_tcp_server.ResponseRouter;

const ControllerContext = struct {
    allocator: std.mem.Allocator,
    address: []const u8,
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    running: *std.atomic.Value(bool),
};

const DatabaseContext = struct {
    allocator: std.mem.Allocator,
    framerate: u16,
    logfile_path: []const u8,
    logfile_dir: std.fs.Dir,
    fsync_on_persist: bool,
    running: *std.atomic.Value(bool),
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    exec_request_ch: *Channel(execution.Request),
    exec_response_ch: *Channel(execution.Response),
};

const ProcessorContext = struct {
    allocator: std.mem.Allocator,
    exec_request_ch: *Channel(execution.Request),
    exec_response_ch: *Channel(execution.Response),
};

fn run_controller(ctx: ControllerContext) void {
    var server = TcpServer.init(ctx.allocator, ctx.address, ctx.running);
    defer server.deinit();
    server.start(ctx.request_ch, ctx.response_router) catch |err| {
        std.debug.print("CONTROLLER: start failed: {}\n", .{err});
        return;
    };
    server.join_all();
}

fn run_database(ctx: DatabaseContext) void {
    var scheduler = Scheduler.init(ctx.allocator);
    scheduler.fsync_on_persist = ctx.fsync_on_persist;
    defer scheduler.deinit();

    scheduler.load(ctx.allocator, ctx.logfile_dir, ctx.logfile_path) catch {};

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
        const resp = ShellRunner.execute(ctx.allocator, req) catch execution.Response{
            .identifier = req.identifier,
            .success = false,
        };
        ctx.exec_response_ch.send(resp) catch return;
    }
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
    }});

    const resp = exec_resp_ch.receive() orelse unreachable;
    try std.testing.expectEqual(@as(u128, 0xdeadbeef), resp.identifier);
    try std.testing.expect(resp.success);

    exec_req_ch.close();
    thread.join();
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
    }});

    const resp = exec_resp_ch.receive() orelse unreachable;
    try std.testing.expectEqual(@as(u128, 0xcafe), resp.identifier);
    try std.testing.expect(!resp.success);

    exec_req_ch.close();
    thread.join();
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

    const args = try interfaces_cli.Args.parse(allocator);
    defer if (args.config_path) |p| allocator.free(p);
    const cfg = try interfaces_config.load(allocator, args.config_path);
    defer cfg.deinit(allocator);

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

    const controller_thread = try std.Thread.spawn(.{}, run_controller, .{ControllerContext{
        .allocator = allocator,
        .address = cfg.controller_listen,
        .request_ch = &query_request_ch,
        .response_router = &response_router,
        .running = &running,
    }});

    const database_thread = try std.Thread.spawn(.{}, run_database, .{DatabaseContext{
        .allocator = allocator,
        .framerate = cfg.database_framerate,
        .logfile_path = cfg.database_logfile_path,
        .logfile_dir = cwd,
        .fsync_on_persist = cfg.database_fsync_on_persist,
        .running = &running,
        .request_ch = &query_request_ch,
        .response_router = &response_router,
        .exec_request_ch = &exec_request_ch,
        .exec_response_ch = &exec_response_ch,
    }});

    const processor_thread = try std.Thread.spawn(.{}, run_processor, .{ProcessorContext{
        .allocator = allocator,
        .exec_request_ch = &exec_request_ch,
        .exec_response_ch = &exec_response_ch,
    }});

    controller_thread.join();

    running.store(false, .release);
    query_request_ch.close();

    database_thread.join();

    exec_request_ch.close();
    processor_thread.join();
}
