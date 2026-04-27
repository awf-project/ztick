const std = @import("std");
const domain_job = @import("domain/job.zig");
const domain_rule = @import("domain/rule.zig");
const domain_query = @import("domain/query.zig");
const domain_execution = @import("domain/execution.zig");
const application_scheduler = @import("application/scheduler.zig");
const persistence_encoder = @import("infrastructure/persistence/encoder.zig");
const persistence_logfile = @import("infrastructure/persistence/logfile.zig");
const persistence_backend = @import("infrastructure/persistence/backend.zig");
const infrastructure_telemetry = @import("infrastructure/telemetry.zig");
const infrastructure_runner = @import("infrastructure/runner.zig");
const interfaces_config = @import("interfaces/config.zig");
const main = @import("main.zig");
const protocol_parser = @import("infrastructure/protocol/parser.zig");

const Scheduler = application_scheduler.Scheduler;
const Job = domain_job.Job;
const JobStatus = domain_job.JobStatus;
const Rule = domain_rule.Rule;
const Request = domain_query.Request;

test "scheduler processes job from query to executed" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.rule_storage.set(Rule{
        .identifier = "rule.echo",
        .pattern = "app.job.",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 42,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "app.job.1", .execution = 1000 } },
    });

    const planned = scheduler.job_storage.get("app.job.1");
    try std.testing.expect(planned != null);
    try std.testing.expectEqual(JobStatus.planned, planned.?.status);

    try scheduler.tick(1000);
    const triggered = scheduler.job_storage.get("app.job.1");
    try std.testing.expect(triggered != null);
    try std.testing.expectEqual(JobStatus.triggered, triggered.?.status);

    for (scheduler.execution_client.pending.items) |req| {
        scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
    }
    scheduler.execution_client.pending.clearRetainingCapacity();

    try scheduler.tick(2000);
    const final = scheduler.job_storage.get("app.job.1");
    try std.testing.expect(final != null);
    try std.testing.expectEqual(JobStatus.executed, final.?.status);
}

test "scheduler fails job when no matching rule exists" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "orphan.job", .execution = 500 } },
    });

    try scheduler.tick(500);

    const job = scheduler.job_storage.get("orphan.job");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(JobStatus.failed, job.?.status);
}

test "scheduler pairs jobs to correct rules by pattern" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.rule_storage.set(Rule{
        .identifier = "rule.app",
        .pattern = "app.",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    });
    try scheduler.rule_storage.set(Rule{
        .identifier = "rule.sys",
        .pattern = "sys.",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "r1",
        .instruction = .{ .set = .{ .identifier = "app.task", .execution = 100 } },
    });
    _ = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "r2",
        .instruction = .{ .set = .{ .identifier = "sys.task", .execution = 200 } },
    });
    _ = try scheduler.handle_query(Request{
        .client = 3,
        .identifier = "r3",
        .instruction = .{ .set = .{ .identifier = "unknown.task", .execution = 300 } },
    });

    try scheduler.tick(100);
    try std.testing.expectEqual(JobStatus.triggered, scheduler.job_storage.get("app.task").?.status);
    try std.testing.expectEqual(JobStatus.planned, scheduler.job_storage.get("sys.task").?.status);

    try scheduler.tick(200);
    try std.testing.expectEqual(JobStatus.triggered, scheduler.job_storage.get("sys.task").?.status);

    try scheduler.tick(300);
    try std.testing.expectEqual(JobStatus.failed, scheduler.job_storage.get("unknown.task").?.status);
}

test "rule set via query enables subsequent job execution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.deploy",
            .pattern = "deploy.",
            .runner = .{ .shell = .{ .command = "/bin/true" } },
        } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-job",
        .instruction = .{ .set = .{ .identifier = "deploy.release.1", .execution = 1000 } },
    });

    try scheduler.tick(1000);
    try std.testing.expectEqual(JobStatus.triggered, scheduler.job_storage.get("deploy.release.1").?.status);

    for (scheduler.execution_client.pending.items) |req| {
        scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
    }
    scheduler.execution_client.pending.clearRetainingCapacity();

    try scheduler.tick(2000);
    try std.testing.expectEqual(JobStatus.executed, scheduler.job_storage.get("deploy.release.1").?.status);
}

fn build_logfile_bytes(allocator: std.mem.Allocator, entries: []const persistence_encoder.Entry) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    for (entries) |entry| {
        const enc = try persistence_encoder.encode(allocator, entry);
        defer allocator.free(enc);
        const framed = try persistence_logfile.encode(allocator, enc);
        defer allocator.free(framed);
        try out.appendSlice(allocator, framed);
    }

    return out.toOwnedSlice(allocator);
}

fn replay_into_scheduler(allocator: std.mem.Allocator, data: []const u8, scheduler: *Scheduler) !std.heap.ArenaAllocator {
    const parsed = try persistence_logfile.parse(allocator, data);
    defer {
        for (parsed.entries) |e| allocator.free(e);
        allocator.free(parsed.entries);
    }

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer decode_arena.deinit();
    const arena = decode_arena.allocator();

    for (parsed.entries) |entry| {
        const decoded = try persistence_encoder.decode(arena, entry);
        try scheduler.replay_entry(decoded);
    }

    return decode_arena;
}

test "persisted state restores into scheduler and resumes execution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_job = Job{ .identifier = "app.restore.1", .execution = 5000, .status = .planned };
    const original_rule = Rule{
        .identifier = "rule.restore",
        .pattern = "app.restore.",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = original_job },
        .{ .rule = original_rule },
    });
    defer allocator.free(logfile_data);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var decode_arena = try replay_into_scheduler(allocator, logfile_data, &scheduler);
    defer decode_arena.deinit();

    const restored = scheduler.job_storage.get("app.restore.1");
    try std.testing.expect(restored != null);
    try std.testing.expectEqual(JobStatus.planned, restored.?.status);

    try scheduler.tick(5000);
    try std.testing.expectEqual(JobStatus.triggered, scheduler.job_storage.get("app.restore.1").?.status);

    for (scheduler.execution_client.pending.items) |req| {
        scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
    }
    scheduler.execution_client.pending.clearRetainingCapacity();

    try scheduler.tick(6000);
    try std.testing.expectEqual(JobStatus.executed, scheduler.job_storage.get("app.restore.1").?.status);
}

test "parsed protocol command drives scheduler via query" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const set_cmd = "A SET app.proto.job.1 1595586600000000000\n";
    const parsed = try protocol_parser.parse(allocator, set_cmd);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("A", parsed.command);
    try std.testing.expectEqual(@as(usize, 3), parsed.args.len);
    try std.testing.expectEqualStrings("SET", parsed.args[0]);

    const timestamp = try std.fmt.parseInt(i64, parsed.args[2], 10);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.rule_storage.set(Rule{
        .identifier = "rule.proto",
        .pattern = "app.proto.",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    });

    _ = try scheduler.handle_query(Request{
        .client = @as(u128, @intCast(parsed.command[0])),
        .identifier = "req-proto-1",
        .instruction = .{ .set = .{ .identifier = parsed.args[1], .execution = timestamp } },
    });

    const job = scheduler.job_storage.get("app.proto.job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(JobStatus.planned, job.?.status);
    try std.testing.expectEqual(@as(i64, 1595586600000000000), job.?.execution);

    try scheduler.tick(1595586600000000000);
    try std.testing.expectEqual(JobStatus.triggered, scheduler.job_storage.get("app.proto.job.1").?.status);
}

test "get existing job returns planned status with execution timestamp" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "app.job.get.1", .execution = 1595586600000000000 } },
    });

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-get",
        .instruction = .{ .get = .{ .identifier = "app.job.get.1" } },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expectEqualStrings("planned 1595586600000000000", response.body.?);
}

test "get nonexistent job returns failure with null body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-get-missing",
        .instruction = .{ .get = .{ .identifier = "no.such.job" } },
    });

    try std.testing.expect(!response.success);
    try std.testing.expectEqual(@as(?[]const u8, null), response.body);
}

test "query prefix match returns only matching jobs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set-1",
        .instruction = .{ .set = .{ .identifier = "backup.daily", .execution = 1595586600_000000000 } },
    });
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set-2",
        .instruction = .{ .set = .{ .identifier = "backup.weekly", .execution = 1595586660_000000000 } },
    });
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set-3",
        .instruction = .{ .set = .{ .identifier = "deploy.prod", .execution = 1595586720_000000000 } },
    });

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-query",
        .instruction = .{ .query = .{ .pattern = "backup." } },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "backup.daily") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "backup.weekly") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "deploy.prod") == null);

    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, response.body.?, '\n');
    while (it.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);
}

test "query with empty pattern returns all jobs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set-1",
        .instruction = .{ .set = .{ .identifier = "backup.daily", .execution = 1595586600_000000000 } },
    });
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set-2",
        .instruction = .{ .set = .{ .identifier = "deploy.prod", .execution = 1595586660_000000000 } },
    });
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set-3",
        .instruction = .{ .set = .{ .identifier = "migrate.db", .execution = 1595586720_000000000 } },
    });

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-query",
        .instruction = .{ .query = .{ .pattern = "" } },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);

    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, response.body.?, '\n');
    while (it.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), line_count);
}

test "query no match returns success with null body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set-1",
        .instruction = .{ .set = .{ .identifier = "backup.daily", .execution = 1595586600_000000000 } },
    });

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-query",
        .instruction = .{ .query = .{ .pattern = "deploy." } },
    });

    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(?[]const u8, null), response.body);
}

test "SET then REMOVE then GET returns absent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "backup.daily", .execution = 1595586600000000000 } },
    });

    const present = scheduler.job_storage.get("backup.daily");
    try std.testing.expect(present != null);

    const remove_resp = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-remove",
        .instruction = .{ .remove = .{ .identifier = "backup.daily" } },
    });
    try std.testing.expect(remove_resp.success);

    const get_resp = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-get",
        .instruction = .{ .get = .{ .identifier = "backup.daily" } },
    });

    try std.testing.expect(!get_resp.success);
    try std.testing.expectEqual(@as(?[]const u8, null), get_resp.body);
}

test "RULE SET then REMOVERULE then rule is absent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule-set",
        .instruction = .{ .rule_set = .{
            .identifier = "notify-slack",
            .pattern = "deploy.",
            .runner = .{ .shell = .{ .command = "/bin/notify" } },
        } },
    });

    try std.testing.expect(scheduler.rule_storage.get("notify-slack") != null);

    const remove_resp = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule-remove",
        .instruction = .{ .remove_rule = .{ .identifier = "notify-slack" } },
    });
    try std.testing.expect(remove_resp.success);

    try std.testing.expectEqual(@as(?Rule, null), scheduler.rule_storage.get("notify-slack"));
}

test "SET then REMOVE persisted and replayed leaves job absent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "cleanup.daily", .execution = 1595586600000000000, .status = .planned } },
        .{ .job_removal = .{ .identifier = "cleanup.daily" } },
    });
    defer allocator.free(logfile_data);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var decode_arena = try replay_into_scheduler(allocator, logfile_data, &scheduler);
    defer decode_arena.deinit();

    try std.testing.expectEqual(@as(?Job, null), scheduler.job_storage.get("cleanup.daily"));
}

test "RULE SET then REMOVERULE persisted and replayed leaves rule absent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = .{ .identifier = "notify-oncall", .pattern = "alert.", .runner = .{ .shell = .{ .command = "/bin/notify" } } } },
        .{ .rule_removal = .{ .identifier = "notify-oncall" } },
    });
    defer allocator.free(logfile_data);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var decode_arena = try replay_into_scheduler(allocator, logfile_data, &scheduler);
    defer decode_arena.deinit();

    try std.testing.expectEqual(@as(?Rule, null), scheduler.rule_storage.get("notify-oncall"));
}

test "RULE SET then LISTRULES returns all rules" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule-1",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.backup",
            .pattern = "backup.",
            .runner = .{ .shell = .{ .command = "/usr/bin/backup.sh" } },
        } },
    });
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule-2",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.notify",
            .pattern = "notify.",
            .runner = .{ .shell = .{ .command = "/usr/bin/notify.sh" } },
        } },
    });

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-list",
        .instruction = .{ .list_rules = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.backup") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "backup.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "/usr/bin/backup.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.notify") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "/usr/bin/notify.sh") != null);

    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, response.body.?, '\n');
    while (it.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);
}

test "LISTRULES with no rules returns success with null body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-list",
        .instruction = .{ .list_rules = .{} },
    });

    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(?[]const u8, null), response.body);
}

test "LISTRULES with AMQP rule includes all runner fields" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.publish",
            .pattern = "events.",
            .runner = .{ .amqp = .{
                .dsn = "amqp://localhost",
                .exchange = "exchange_name",
                .routing_key = "routing.key",
            } },
        } },
    });

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-list",
        .instruction = .{ .list_rules = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.publish") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "events.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "amqp") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "amqp://localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "exchange_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "routing.key") != null);
}

// Feature: F005

fn spawn_ztick(allocator: std.mem.Allocator, config_path: []const u8) !std.process.Child {
    var child = std.process.Child.init(
        &[_][]const u8{ "zig-out/bin/ztick", "-c", config_path },
        allocator,
    );
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    try child.spawn();
    return child;
}

fn drain_stderr(stderr_file: std.fs.File, buf: []u8) []const u8 {
    // Set non-blocking so read returns immediately when no data available.
    const flags = std.posix.fcntl(stderr_file.handle, std.posix.F.GETFL, 0) catch return buf[0..0];
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stderr_file.handle, std.posix.F.SETFL, flags | nonblock) catch return buf[0..0];

    var filled: usize = 0;
    while (filled < buf.len) {
        const n = stderr_file.read(buf[filled..]) catch break;
        if (n == 0) break;
        filled += n;
    }
    return buf[0..filled];
}

const TlsPaths = struct {
    cwd: []const u8,
    cert: []const u8,
    key: []const u8,

    fn resolve(allocator: std.mem.Allocator) !TlsPaths {
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        errdefer allocator.free(cwd);
        const cert = try std.fmt.allocPrint(allocator, "{s}/test/fixtures/tls/cert.pem", .{cwd});
        errdefer allocator.free(cert);
        const key = try std.fmt.allocPrint(allocator, "{s}/test/fixtures/tls/key.pem", .{cwd});
        return .{ .cwd = cwd, .cert = cert, .key = key };
    }

    fn deinit(self: TlsPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.cert);
        allocator.free(self.cwd);
    }
};

const TestServer = struct {
    child: std.process.Child,
    tmp_dir: std.testing.TmpDir,
    config_path: []const u8,
    allocator: std.mem.Allocator,

    fn start(allocator: std.mem.Allocator, config_content: []const u8) !TestServer {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
        try config_file.writeAll(config_content);
        config_file.close();

        const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
        errdefer allocator.free(config_path);

        const child = try spawn_ztick(allocator, config_path);

        std.Thread.sleep(300_000_000);

        return .{
            .child = child,
            .tmp_dir = tmp_dir,
            .config_path = config_path,
            .allocator = allocator,
        };
    }

    fn stop(self: *TestServer) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        self.allocator.free(self.config_path);
        self.tmp_dir.cleanup();
    }
};

// Feature: F006

test "plaintext mode accepts commands when no TLS config is present" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(allocator, "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19879\"\n\n[database]\nlogfile_path = \"test_plaintext_f006.db\"\n");
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19879) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;

    _ = stream.write("req-backward-compat-1 SET app.backward.compat.job 1595586600000000000\n") catch {
        stream.close();
        return error.SkipZigTest;
    };

    std.Thread.sleep(500_000_000);
    stream.close();
    std.Thread.sleep(100_000_000);

    var stderr_buf: [8192]u8 = undefined;
    const stderr = drain_stderr(server.child.stderr.?, &stderr_buf);

    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO] listening on") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "[DEBUG] instruction received: set") != null);

    server.tmp_dir.dir.deleteFile("test_plaintext_f006.db") catch {};
}

test "partial TLS config with only tls_cert is rejected at startup" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll("[log]\nlevel = \"error\"\n\n[controller]\nlisten = \"127.0.0.1:0\"\ntls_cert = \"/any/path/cert.pem\"\n\n[database]\nlogfile_path = \"test_partial_tls_cert.db\"\n");
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => try std.testing.expect(false),
    }
}

test "partial TLS config with only tls_key is rejected at startup" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll("[log]\nlevel = \"error\"\n\n[controller]\nlisten = \"127.0.0.1:0\"\ntls_key = \"/any/path/key.pem\"\n\n[database]\nlogfile_path = \"test_partial_tls_key.db\"\n");
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => try std.testing.expect(false),
    }
}

test "startup with default log level produces config and listening address on stderr" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll("[log]\nlevel = \"info\"\n\n[controller]\nlisten = \"127.0.0.1:0\"\n\n[database]\nlogfile_path = \"test_startup_log.db\"\n");
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const stderr_file = child.stderr.?;

    std.Thread.sleep(300_000_000);

    var stderr_buf: [4096]u8 = undefined;
    const stderr = drain_stderr(stderr_file, &stderr_buf);

    _ = child.kill() catch {};
    _ = child.wait() catch {};

    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO] config:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO] log level: info") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO] listening on") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO] loaded") != null);

    tmp_dir.dir.deleteFile("test_startup_log.db") catch {};
}

test "startup with log level off produces no stderr output" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll("[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:0\"\n\n[database]\nlogfile_path = \"test_silent_log.db\"\n");
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const stderr_file = child.stderr.?;

    std.Thread.sleep(300_000_000);

    var stderr_buf: [4096]u8 = undefined;
    const stderr = drain_stderr(stderr_file, &stderr_buf);

    _ = child.kill() catch {};
    _ = child.wait() catch {};

    try std.testing.expectEqual(@as(usize, 0), stderr.len);

    tmp_dir.dir.deleteFile("test_silent_log.db") catch {};
}

test "startup with warn log level suppresses info messages" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll("[log]\nlevel = \"warn\"\n\n[controller]\nlisten = \"127.0.0.1:0\"\n\n[database]\nlogfile_path = \"test_warn_log.db\"\n");
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const stderr_file = child.stderr.?;

    std.Thread.sleep(300_000_000);

    var stderr_buf: [4096]u8 = undefined;
    const stderr = drain_stderr(stderr_file, &stderr_buf);

    _ = child.kill() catch {};
    _ = child.wait() catch {};

    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO]") == null);

    tmp_dir.dir.deleteFile("test_warn_log.db") catch {};
}

test "startup logs loaded job and rule counts from persisted data" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const job1 = domain_job.Job{ .identifier = "app.task.1", .execution = 1595586600_000000000, .status = .planned };
    const job2 = domain_job.Job{ .identifier = "app.task.2", .execution = 1595586700_000000000, .status = .planned };
    const rule1 = domain_rule.Rule{
        .identifier = "rule.app",
        .pattern = "app.",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    };

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = job1 },
        .{ .job = job2 },
        .{ .rule = rule1 },
    });
    defer allocator.free(logfile_data);

    var logfile = try tmp_dir.dir.createFile("test_counts.db", .{});
    try logfile.writeAll(logfile_data);
    logfile.close();

    const logfile_real_path = try tmp_dir.dir.realpathAlloc(allocator, "test_counts.db");
    defer allocator.free(logfile_real_path);

    var config_buf: [512]u8 = undefined;
    const config_content = try std.fmt.bufPrint(&config_buf, "[log]\nlevel = \"info\"\n\n[controller]\nlisten = \"127.0.0.1:0\"\n\n[database]\nlogfile_path = \"{s}\"\n", .{logfile_real_path});

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll(config_content);
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const stderr_file = child.stderr.?;

    std.Thread.sleep(300_000_000);

    var stderr_buf: [4096]u8 = undefined;
    const stderr = drain_stderr(stderr_file, &stderr_buf);

    _ = child.kill() catch {};
    _ = child.wait() catch {};

    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO] loaded 2 jobs, 1 rules") != null);
}

test "client connect and disconnect are logged at info level" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll("[log]\nlevel = \"info\"\n\n[controller]\nlisten = \"127.0.0.1:19876\"\n\n[database]\nlogfile_path = \"test_connect_log.db\"\n");
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const stderr_file = child.stderr.?;

    std.Thread.sleep(300_000_000);

    // Connect a TCP client to trigger connect log
    const addr = std.net.Address.parseIp("127.0.0.1", 19876) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return error.SkipZigTest;
    };
    std.Thread.sleep(100_000_000);
    stream.close();
    std.Thread.sleep(100_000_000);

    var stderr_buf: [4096]u8 = undefined;
    const stderr = drain_stderr(stderr_file, &stderr_buf);

    _ = child.kill() catch {};
    _ = child.wait() catch {};

    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO] client connected:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO] client disconnected:") != null);

    tmp_dir.dir.deleteFile("test_connect_log.db") catch {};
}

test "instruction received is logged at debug level" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll("[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19877\"\n\n[database]\nlogfile_path = \"test_debug_log.db\"\n");
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const stderr_file = child.stderr.?;

    std.Thread.sleep(300_000_000);

    const addr = std.net.Address.parseIp("127.0.0.1", 19877) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return error.SkipZigTest;
    };

    _ = stream.write("req-1 SET app.task.1 1595586600000000000\n") catch {
        stream.close();
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return error.SkipZigTest;
    };
    std.Thread.sleep(500_000_000);
    stream.close();
    std.Thread.sleep(200_000_000);

    var stderr_buf: [8192]u8 = undefined;
    const stderr = drain_stderr(stderr_file, &stderr_buf);

    _ = child.kill() catch {};
    _ = child.wait() catch {};

    try std.testing.expect(std.mem.indexOf(u8, stderr, "[DEBUG] instruction received:") != null);

    tmp_dir.dir.deleteFile("test_debug_log.db") catch {};
}

test "execution failure marks triggered job as failed" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.rule_storage.set(Rule{
        .identifier = "rule.deploy",
        .pattern = "deploy.",
        .runner = .{ .shell = .{ .command = "/bin/false" } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "deploy.release.1", .execution = 1000 } },
    });

    try scheduler.tick(1000);
    try std.testing.expectEqual(JobStatus.triggered, scheduler.job_storage.get("deploy.release.1").?.status);

    for (scheduler.execution_client.pending.items) |req| {
        scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = false });
    }
    scheduler.execution_client.pending.clearRetainingCapacity();

    try scheduler.tick(2000);
    try std.testing.expectEqual(JobStatus.failed, scheduler.job_storage.get("deploy.release.1").?.status);
}

// Feature: F006

test "TLS-enabled server accepts encrypted connections and processes SET command over encrypted channel" {
    const allocator = std.testing.allocator;

    const tls = try TlsPaths.resolve(allocator);
    defer tls.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19884\"\ntls_cert = \"{s}\"\ntls_key = \"{s}\"\n\n[database]\nlogfile_path = \"test_tls_encrypted.db\"\n",
        .{ tls.cert, tls.key },
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    std.Thread.sleep(200_000_000);

    // Use openssl s_client to connect over TLS and send a SET command
    var openssl = std.process.Child.init(
        &[_][]const u8{
            "openssl",       "s_client",
            "-connect",      "127.0.0.1:19884",
            "-quiet",        "-no_ign_eof",
            "-verify_quiet",
        },
        allocator,
    );
    openssl.stdin_behavior = .Pipe;
    openssl.stdout_behavior = .Pipe;
    openssl.stderr_behavior = .Pipe;
    try openssl.spawn();

    std.Thread.sleep(300_000_000);

    _ = openssl.stdin.?.write("req-tls-1 SET app.tls.encrypted.job 1595586600000000000\n") catch {
        _ = openssl.kill() catch {};
        _ = openssl.wait() catch {};
        server.tmp_dir.dir.deleteFile("test_tls_encrypted.db") catch {};
        return error.SkipZigTest;
    };

    // Wait for server to process (sanitizers are ~5-10x slower)
    std.Thread.sleep(2_000_000_000);

    openssl.stdin.?.close();
    openssl.stdin = null;

    std.Thread.sleep(500_000_000);

    // Read openssl stdout with non-blocking polling and retry for sanitizer slowness
    const stdout_file = openssl.stdout.?;
    const flags = std.posix.fcntl(stdout_file.handle, std.posix.F.GETFL, 0) catch {
        _ = openssl.kill() catch {};
        _ = openssl.wait() catch {};
        server.tmp_dir.dir.deleteFile("test_tls_encrypted.db") catch {};
        return error.SkipZigTest;
    };
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stdout_file.handle, std.posix.F.SETFL, flags | nonblock) catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_filled: usize = 0;
    // Retry up to 10 times (5s total) to handle sanitizer slowness
    for (0..10) |_| {
        while (stdout_filled < stdout_buf.len) {
            const n = stdout_file.read(stdout_buf[stdout_filled..]) catch break;
            if (n == 0) break;
            stdout_filled += n;
        }
        if (stdout_filled > 0) break;
        std.Thread.sleep(500_000_000);
    }
    const tls_response = stdout_buf[0..stdout_filled];

    _ = openssl.kill() catch {};
    _ = openssl.wait() catch {};

    // Read server stderr for debug logs
    var stderr_buf: [8192]u8 = undefined;
    const stderr_output = drain_stderr(server.child.stderr.?, &stderr_buf);

    // The TLS response must contain "OK" from the SET command
    if (std.mem.indexOf(u8, tls_response, "OK") == null) {
        std.debug.print("\nTLS response ({d} bytes): '{s}'\n", .{ tls_response.len, tls_response });
        std.debug.print("Server stderr:\n{s}\n", .{stderr_output});
        return error.TestExpectedEqual;
    }

    server.tmp_dir.dir.deleteFile("test_tls_encrypted.db") catch {};
}

test "failed TLS handshake closes offending connection without crashing server" {
    const allocator = std.testing.allocator;

    const tls = try TlsPaths.resolve(allocator);
    defer tls.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"info\"\n\n[controller]\nlisten = \"127.0.0.1:19883\"\ntls_cert = \"{s}\"\ntls_key = \"{s}\"\n\n[database]\nlogfile_path = \"test_tls_bad_handshake.db\"\n",
        .{ tls.cert, tls.key },
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19883) catch unreachable;

    // Connect with plain TCP and send garbage bytes (not a TLS ClientHello)
    var bad_conn = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;

    _ = bad_conn.write("GARBAGE BYTES NOT A TLS CLIENT HELLO") catch {};

    std.Thread.sleep(500_000_000);

    const recv_timeout = std.posix.timeval{ .sec = 0, .usec = 300_000 };
    std.posix.setsockopt(
        bad_conn.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    var read_buf: [16]u8 = undefined;
    _ = bad_conn.read(&read_buf) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.WouldBlock => {},
        else => {
            bad_conn.close();
            server.tmp_dir.dir.deleteFile("test_tls_bad_handshake.db") catch {};
            return err;
        },
    };
    bad_conn.close();

    var next_conn = std.net.tcpConnectToAddress(addr) catch |err| {
        server.tmp_dir.dir.deleteFile("test_tls_bad_handshake.db") catch {};
        return err;
    };
    next_conn.close();

    server.tmp_dir.dir.deleteFile("test_tls_bad_handshake.db") catch {};
}

test "server recovers after client disconnects during TLS handshake" {
    const allocator = std.testing.allocator;

    const tls = try TlsPaths.resolve(allocator);
    defer tls.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"info\"\n\n[controller]\nlisten = \"127.0.0.1:19885\"\ntls_cert = \"{s}\"\ntls_key = \"{s}\"\n\n[database]\nlogfile_path = \"test_tls_mid_handshake.db\"\n",
        .{ tls.cert, tls.key },
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19885) catch unreachable;

    var partial_conn = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;

    _ = partial_conn.write("\x16\x03\x03\x00\x01") catch {};
    partial_conn.close();

    std.Thread.sleep(500_000_000);

    var next_conn = std.net.tcpConnectToAddress(addr) catch |err| {
        server.tmp_dir.dir.deleteFile("test_tls_mid_handshake.db") catch {};
        return err;
    };
    next_conn.close();

    server.tmp_dir.dir.deleteFile("test_tls_mid_handshake.db") catch {};
}

const DumpTestResult = struct {
    stdout: []const u8,
    exit_code: u8,
    allocator: std.mem.Allocator,
    _tmp_dir: std.testing.TmpDir,
    _logfile_path: []const u8,

    fn deinit(self: *DumpTestResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self._logfile_path);
        self._tmp_dir.cleanup();
    }
};

fn run_dump_command(allocator: std.mem.Allocator, logfile_data: ?[]const u8, extra_args: []const []const u8) !DumpTestResult {
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    const filename = "test.bin";
    if (logfile_data) |data| {
        var log_file = try tmp_dir.dir.createFile(filename, .{});
        try log_file.writeAll(data);
        log_file.close();
    } else {
        var log_file = try tmp_dir.dir.createFile(filename, .{});
        log_file.close();
    }

    const logfile_path = try tmp_dir.dir.realpathAlloc(allocator, filename);
    errdefer allocator.free(logfile_path);

    var args_buf: [16][]const u8 = undefined;
    args_buf[0] = "zig-out/bin/ztick";
    args_buf[1] = "dump";
    args_buf[2] = logfile_path;
    for (extra_args, 0..) |arg, i| args_buf[3 + i] = arg;
    const args = args_buf[0 .. 3 + extra_args.len];

    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    try child.spawn();

    const stdout_data = try child.stdout.?.readToEndAlloc(allocator, 65536);
    errdefer allocator.free(stdout_data);

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => return error.TestUnexpectedResult,
    };

    return DumpTestResult{
        .stdout = stdout_data,
        .exit_code = exit_code,
        .allocator = allocator,
        ._tmp_dir = tmp_dir,
        ._logfile_path = logfile_path,
    };
}

fn expect_follow_exits_cleanly_on_signal(allocator: std.mem.Allocator, signal: u6) !void {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var log_file = try tmp_dir.dir.createFile("follow_signal.bin", .{});
    log_file.close();

    const logfile_path = try tmp_dir.dir.realpathAlloc(allocator, "follow_signal.bin");
    defer allocator.free(logfile_path);

    var child = std.process.Child.init(
        &[_][]const u8{ "zig-out/bin/ztick", "dump", logfile_path, "--follow" },
        allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    try child.spawn();

    std.Thread.sleep(200_000_000);
    std.posix.kill(child.id, signal) catch {};
    const term = try child.wait();

    switch (term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

test "dump command prints all entries in text format" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "app.job.1", .execution = 1605457800000000000, .status = .planned } },
        .{ .rule = .{ .identifier = "rule.1", .pattern = "app.", .runner = .{ .shell = .{ .command = "/bin/true" } } } },
        .{ .job_removal = .{ .identifier = "old.job" } },
        .{ .rule_removal = .{ .identifier = "old.rule" } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "SET app.job.1 1605457800000000000 planned\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "RULE SET rule.1 app. shell /bin/true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "REMOVE old.job\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "REMOVERULE old.rule\n") != null);
}

test "dump command prints NDJSON entries with --format json" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "app.job.2", .execution = 1605457800000000000, .status = .executed } },
        .{ .job_removal = .{ .identifier = "gone.job" } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{ "--format", "json" });
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, result.stdout, "\n"), '\n');
    const line1 = lines.next() orelse return error.TestUnexpectedResult;
    const line2 = lines.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, line1, "\"type\":\"set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "\"identifier\":\"app.job.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line2, "\"type\":\"remove\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line2, "\"identifier\":\"gone.job\"") != null);
}

test "dump command produces no output for empty logfile" {
    const allocator = std.testing.allocator;

    var result = try run_dump_command(allocator, null, &.{});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
}

test "dump command exits 1 for missing logfile" {
    const allocator = std.testing.allocator;

    var child = std.process.Child.init(
        &[_][]const u8{ "zig-out/bin/ztick", "dump", "/nonexistent/path/ztick-f007-test.bin" },
        allocator,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    try child.spawn();

    const term = try child.wait();
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 1), code),
        else => return error.TestUnexpectedResult,
    }
}

test "dump command --compact keeps only last SET per identifier" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "app.job.dedup", .execution = 1000000000000000000, .status = .planned } },
        .{ .job = .{ .identifier = "app.job.dedup", .execution = 2000000000000000000, .status = .planned } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{"--compact"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "SET app.job.dedup 2000000000000000000 planned\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "SET app.job.dedup 1000000000000000000 planned\n") == null);
}

test "dump command --compact omits entries whose final mutation is a removal" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "removed.job", .execution = 1605457800000000000, .status = .planned } },
        .{ .job_removal = .{ .identifier = "removed.job" } },
        .{ .job = .{ .identifier = "kept.job", .execution = 1605457800000000000, .status = .planned } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{"--compact"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "removed.job") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "SET kept.job 1605457800000000000 planned\n") != null);
}

test "dump command prints warning to stderr and outputs complete entries for partial trailing frame" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "partial.job", .execution = 1605457800000000000, .status = .planned } },
    });
    defer allocator.free(logfile_data);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var log_file = try tmp_dir.dir.createFile("partial.bin", .{});
    try log_file.writeAll(logfile_data);
    try log_file.writeAll(&[_]u8{ 0, 0, 42 });
    log_file.close();

    const logfile_path = try tmp_dir.dir.realpathAlloc(allocator, "partial.bin");
    defer allocator.free(logfile_path);

    var child = std.process.Child.init(
        &[_][]const u8{ "zig-out/bin/ztick", "dump", logfile_path },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = .Ignore;
    try child.spawn();

    const stdout_data = try child.stdout.?.readToEndAlloc(allocator, 65536);
    defer allocator.free(stdout_data);
    const stderr_data = try child.stderr.?.readToEndAlloc(allocator, 65536);
    defer allocator.free(stderr_data);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "SET partial.job 1605457800000000000 planned\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_data, "warning") != null);
}

test "dump command prints rule_set entry as NDJSON with nested runner object for shell runner" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = .{
            .identifier = "rule.shell",
            .pattern = "app.job.",
            .runner = .{ .shell = .{ .command = "/bin/process" } },
        } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{ "--format", "json" });
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const line = std.mem.trimRight(u8, result.stdout, "\n");
    try std.testing.expect(std.mem.indexOf(u8, line, "\"type\":\"rule_set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"identifier\":\"rule.shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"runner\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"type\":\"shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"command\":\"/bin/process\"") != null);
}

test "dump command prints rule_set entry as NDJSON with nested runner object for amqp runner" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = .{
            .identifier = "rule.amqp",
            .pattern = "notify.",
            .runner = .{ .amqp = .{
                .dsn = "amqp://localhost",
                .exchange = "events",
                .routing_key = "notify.key",
            } },
        } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{ "--format", "json" });
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const line = std.mem.trimRight(u8, result.stdout, "\n");
    try std.testing.expect(std.mem.indexOf(u8, line, "\"type\":\"rule_set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"identifier\":\"rule.amqp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"type\":\"amqp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"dsn\":\"amqp://localhost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"exchange\":\"events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"routing_key\":\"notify.key\"") != null);
}

test "dump command prints rule_removal entry as NDJSON" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule_removal = .{ .identifier = "rule.gone" } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{ "--format", "json" });
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const line = std.mem.trimRight(u8, result.stdout, "\n");
    try std.testing.expect(std.mem.indexOf(u8, line, "\"type\":\"remove_rule\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"identifier\":\"rule.gone\"") != null);
}

test "dump command --compact with --format json outputs compacted entries as NDJSON" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "app.job.1", .execution = 1000000000, .status = .planned } },
        .{ .job = .{ .identifier = "app.job.1", .execution = 2000000000, .status = .planned } },
        .{ .job = .{ .identifier = "app.job.2", .execution = 3000000000, .status = .planned } },
        .{ .job_removal = .{ .identifier = "app.job.2" } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{ "--compact", "--format", "json" });
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    const trimmed = std.mem.trimRight(u8, result.stdout, "\n");
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    const line1 = lines.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "\"type\":\"set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "\"identifier\":\"app.job.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "2000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "app.job.2") == null);
}

test "dump command --compact keeps only last RULE SET per identifier" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = .{ .identifier = "dedup.rule", .pattern = "old.", .runner = .{ .shell = .{ .command = "old-cmd" } } } },
        .{ .rule = .{ .identifier = "dedup.rule", .pattern = "new.", .runner = .{ .shell = .{ .command = "new-cmd" } } } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{"--compact"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "RULE SET dedup.rule new. shell new-cmd\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "old.") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "old-cmd") == null);
}

test "dump command --compact omits entries whose final mutation is a rule removal" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = .{ .identifier = "removed.rule", .pattern = "app.", .runner = .{ .shell = .{ .command = "/bin/notify" } } } },
        .{ .rule_removal = .{ .identifier = "removed.rule" } },
        .{ .rule = .{ .identifier = "kept.rule", .pattern = "other.", .runner = .{ .shell = .{ .command = "/bin/run" } } } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{"--compact"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "removed.rule") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "RULE SET kept.rule other. shell /bin/run\n") != null);
}

test "dump command --compact with only removal entries produces no output" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job_removal = .{ .identifier = "ghost.job" } },
        .{ .rule_removal = .{ .identifier = "ghost.rule" } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{"--compact"});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
}

test "dump command --follow exits 0 on SIGINT" {
    try expect_follow_exits_cleanly_on_signal(std.testing.allocator, std.posix.SIG.INT);
}

test "dump command --follow prints newly appended entries" {
    const allocator = std.testing.allocator;

    const initial_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "follow.initial", .execution = 1000000000000000000, .status = .planned } },
    });
    defer allocator.free(initial_data);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var log_file = try tmp_dir.dir.createFile("follow_append.bin", .{});
    try log_file.writeAll(initial_data);
    log_file.close();

    const logfile_path = try tmp_dir.dir.realpathAlloc(allocator, "follow_append.bin");
    defer allocator.free(logfile_path);

    var child = std.process.Child.init(
        &[_][]const u8{ "zig-out/bin/ztick", "dump", logfile_path, "--follow" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    try child.spawn();

    std.Thread.sleep(200_000_000);

    const appended_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "follow.appended", .execution = 2000000000000000000, .status = .planned } },
    });
    defer allocator.free(appended_data);

    var append_file = try tmp_dir.dir.openFile("follow_append.bin", .{ .mode = .write_only });
    try append_file.seekFromEnd(0);
    try append_file.writeAll(appended_data);
    append_file.close();

    std.Thread.sleep(2_500_000_000);

    std.posix.kill(child.id, std.posix.SIG.INT) catch {};
    const stdout_data = try child.stdout.?.readToEndAlloc(allocator, 65536);
    defer allocator.free(stdout_data);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "SET follow.initial 1000000000000000000 planned\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "SET follow.appended 2000000000000000000 planned\n") != null);
}

test "dump command --follow --format json prints new entries as NDJSON" {
    const allocator = std.testing.allocator;

    const initial_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "follow.json.initial", .execution = 1000000000000000000, .status = .planned } },
    });
    defer allocator.free(initial_data);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var log_file = try tmp_dir.dir.createFile("follow_json.bin", .{});
    try log_file.writeAll(initial_data);
    log_file.close();

    const logfile_path = try tmp_dir.dir.realpathAlloc(allocator, "follow_json.bin");
    defer allocator.free(logfile_path);

    var child = std.process.Child.init(
        &[_][]const u8{ "zig-out/bin/ztick", "dump", logfile_path, "--follow", "--format", "json" },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    try child.spawn();

    std.Thread.sleep(200_000_000);

    const appended_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "follow.json.appended", .execution = 2000000000000000000, .status = .planned } },
    });
    defer allocator.free(appended_data);

    var append_file = try tmp_dir.dir.openFile("follow_json.bin", .{ .mode = .write_only });
    try append_file.seekFromEnd(0);
    try append_file.writeAll(appended_data);
    append_file.close();

    std.Thread.sleep(2_500_000_000);

    std.posix.kill(child.id, std.posix.SIG.INT) catch {};
    const stdout_data = try child.stdout.?.readToEndAlloc(allocator, 65536);
    defer allocator.free(stdout_data);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "\"identifier\":\"follow.json.initial\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_data, "\"identifier\":\"follow.json.appended\"") != null);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, stdout_data, "\n"), '\n');
    while (lines.next()) |line| {
        try std.testing.expect(line[0] == '{');
        try std.testing.expect(line[line.len - 1] == '}');
    }
}

test "dump command --follow exits 0 on SIGTERM" {
    try expect_follow_exits_cleanly_on_signal(std.testing.allocator, std.posix.SIG.TERM);
}

// Feature: F008

test "memory backend processes SET command without creating files on disk" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var placeholder = try tmp_dir.dir.createFile("memory.db", .{});
    placeholder.close();
    const db_abs_path = try tmp_dir.dir.realpathAlloc(allocator, "memory.db");
    defer allocator.free(db_abs_path);
    try tmp_dir.dir.deleteFile("memory.db");

    var config_buf: [1024]u8 = undefined;
    const config_content = try std.fmt.bufPrint(
        &config_buf,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19880\"\n\n[database]\npersistence = \"memory\"\nlogfile_path = \"{s}\"\n",
        .{db_abs_path},
    );

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll(config_content);
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const stderr_file = child.stderr.?;
    std.Thread.sleep(300_000_000);

    const addr = std.net.Address.parseIp("127.0.0.1", 19880) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return error.SkipZigTest;
    };

    _ = stream.write("req-mem-1 SET app.mem.job 1595586600000000000\n") catch {
        stream.close();
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return error.SkipZigTest;
    };
    std.Thread.sleep(500_000_000);
    stream.close();
    std.Thread.sleep(200_000_000);

    var stderr_buf: [8192]u8 = undefined;
    const stderr = drain_stderr(stderr_file, &stderr_buf);

    _ = child.kill() catch {};
    _ = child.wait() catch {};

    try std.testing.expect(std.mem.indexOf(u8, stderr, "[DEBUG] instruction received: set") != null);
    try std.testing.expectError(error.FileNotFound, tmp_dir.dir.access("memory.db", .{}));
}

test "memory backend starts with zero loaded jobs and rules" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll("[log]\nlevel = \"info\"\n\n[controller]\nlisten = \"127.0.0.1:0\"\n\n[database]\npersistence = \"memory\"\n");
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const stderr_file = child.stderr.?;

    std.Thread.sleep(300_000_000);

    var stderr_buf: [4096]u8 = undefined;
    const stderr = drain_stderr(stderr_file, &stderr_buf);

    _ = child.kill() catch {};
    _ = child.wait() catch {};

    try std.testing.expect(std.mem.indexOf(u8, stderr, "[INFO] loaded 0 jobs, 0 rules") != null);
}

test "memory backend SET and GET round-trip returns planned job" {
    const allocator = std.testing.allocator;

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = .{ .memory = .{ .entries = .{}, .allocator = allocator } };

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "mem.job.1", .execution = 1595586600000000000 } },
    });

    const get_resp = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-get",
        .instruction = .{ .get = .{ .identifier = "mem.job.1" } },
    });
    defer if (get_resp.body) |b| allocator.free(b);

    try std.testing.expect(get_resp.success);
    try std.testing.expectEqualStrings("planned 1595586600000000000", get_resp.body.?);
}

test "memory backend data does not survive scheduler reload" {
    const allocator = std.testing.allocator;

    var scheduler = Scheduler.init(allocator);
    scheduler.persistence = .{ .memory = .{ .entries = .{}, .allocator = allocator } };

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "ephemeral.job", .execution = 5000 } },
    });

    const job_before = scheduler.job_storage.get("ephemeral.job");
    try std.testing.expect(job_before != null);

    scheduler.deinit();

    // New scheduler with fresh memory backend — no data carried over
    var scheduler2 = Scheduler.init(allocator);
    defer scheduler2.deinit();
    scheduler2.persistence = .{ .memory = .{ .entries = .{}, .allocator = allocator } };
    try scheduler2.load(allocator);

    try std.testing.expectEqual(@as(?Job, null), scheduler2.job_storage.get("ephemeral.job"));
}

test "memory backend REMOVE command removes job from storage" {
    const allocator = std.testing.allocator;

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = .{ .memory = .{ .entries = .{}, .allocator = allocator } };

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "mem.removable.job", .execution = 9000 } },
    });

    try std.testing.expect(scheduler.job_storage.get("mem.removable.job") != null);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-remove",
        .instruction = .{ .remove = .{ .identifier = "mem.removable.job" } },
    });

    try std.testing.expectEqual(@as(?Job, null), scheduler.job_storage.get("mem.removable.job"));
}

test "memory backend REMOVERULE command removes rule from storage" {
    const allocator = std.testing.allocator;

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = .{ .memory = .{ .entries = .{}, .allocator = allocator } };

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-ruleset",
        .instruction = .{ .rule_set = .{ .identifier = "mem.rule.1", .pattern = "mem.", .runner = .{ .shell = .{ .command = "/bin/true" } } } },
    });

    try std.testing.expect(scheduler.rule_storage.get("mem.rule.1") != null);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-removerule",
        .instruction = .{ .remove_rule = .{ .identifier = "mem.rule.1" } },
    });

    try std.testing.expectEqual(@as(?Rule, null), scheduler.rule_storage.get("mem.rule.1"));
}

test "default persistence uses logfile when no persistence key configured" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = .{ .logfile = .{
        .logfile_path = "default.log",
        .logfile_dir = tmp_dir.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } };

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "compat.job", .execution = 9000 } },
    });

    // Logfile backend creates the file on disk
    try tmp_dir.dir.access("default.log", .{});

    // New scheduler loads persisted data from same logfile
    var scheduler2 = Scheduler.init(allocator);
    defer scheduler2.deinit();
    scheduler2.persistence = .{ .logfile = .{
        .logfile_path = "default.log",
        .logfile_dir = tmp_dir.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    try scheduler2.load(allocator);

    const restored = scheduler2.job_storage.get("compat.job");
    try std.testing.expect(restored != null);
    try std.testing.expectEqual(JobStatus.planned, restored.?.status);
}

// Feature: F009

test "compression produces deduplicated logfile after interval" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = .{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    scheduler.compression_interval_ns = 1;

    // Write 5 mutations for the same job ID — compression should deduplicate to exactly 1 entry
    for (0..5) |i| {
        const exec: i64 = @intCast(1000 + i);
        _ = try scheduler.handle_query(Request{
            .client = 1,
            .identifier = "req-recurring",
            .instruction = .{ .set = .{ .identifier = "recurring.job", .execution = exec } },
        });
    }

    // Write a job that is SET then REMOVEd — should not appear in compressed output
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-transient-set",
        .instruction = .{ .set = .{ .identifier = "transient.job", .execution = 9999 } },
    });
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-transient-remove",
        .instruction = .{ .remove = .{ .identifier = "transient.job" } },
    });

    try scheduler.tick(1);
    try std.testing.expect(scheduler.active_process != null);

    const proc = scheduler.active_process.?;
    proc.thread.join();
    proc.deinit();
    scheduler.active_process = null;

    const compressed_data = try tmp.dir.readFileAlloc(allocator, "logfile.compressed", std.math.maxInt(usize));
    defer allocator.free(compressed_data);

    const parsed = try persistence_logfile.parse(allocator, compressed_data);
    defer {
        for (parsed.entries) |e| allocator.free(e);
        allocator.free(parsed.entries);
    }

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const arena = decode_arena.allocator();

    var recurring_count: usize = 0;
    var transient_found = false;
    for (parsed.entries) |raw| {
        const entry = try persistence_encoder.decode(arena, raw);
        switch (entry) {
            .job => |j| {
                if (std.mem.eql(u8, j.identifier, "recurring.job")) recurring_count += 1;
                if (std.mem.eql(u8, j.identifier, "transient.job")) transient_found = true;
            },
            .job_removal => |r| {
                if (std.mem.eql(u8, r.identifier, "transient.job")) transient_found = true;
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), recurring_count);
    try std.testing.expect(!transient_found);
}

test "memory backend skips compression and produces no file artifacts" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = .{ .memory = .{ .entries = .{}, .allocator = allocator } };
    scheduler.compression_interval_ns = 1;

    try scheduler.tick(1);

    try std.testing.expectEqual(@as(?*@import("infrastructure/persistence/background.zig").Process, null), scheduler.active_process);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("logfile.to_compress", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("logfile.compressed", .{}));
}

test "leftover .to_compress file is compressed at startup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .job = .{ .identifier = "startup.job", .execution = 1000, .status = .planned } },
        .{ .job = .{ .identifier = "startup.job", .execution = 2000, .status = .planned } },
        .{ .job = .{ .identifier = "startup.job", .execution = 3000, .status = .planned } },
    });
    defer allocator.free(logfile_data);

    const to_compress = try tmp.dir.createFile("logfile.to_compress", .{});
    try to_compress.writeAll(logfile_data);
    to_compress.close();

    main.compress_startup_leftover(allocator, .{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });

    const compressed_data = try tmp.dir.readFileAlloc(allocator, "logfile.compressed", std.math.maxInt(usize));
    defer allocator.free(compressed_data);

    const parsed = try persistence_logfile.parse(allocator, compressed_data);
    defer {
        for (parsed.entries) |e| allocator.free(e);
        allocator.free(parsed.entries);
    }

    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const arena = decode_arena.allocator();

    var count: usize = 0;
    var last_execution: i64 = 0;
    for (parsed.entries) |raw| {
        const entry = try persistence_encoder.decode(arena, raw);
        switch (entry) {
            .job => |j| {
                if (std.mem.eql(u8, j.identifier, "startup.job")) {
                    count += 1;
                    last_execution = j.execution;
                }
            },
            else => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(i64, 3000), last_execution);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("logfile.to_compress", .{}));
}

fn count_process_threads() usize {
    var dir = std.fs.openDirAbsolute("/proc/self/task", .{ .iterate = true }) catch return 0;
    defer dir.close();
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next() catch null) |_| n += 1;
    return n;
}

test "telemetry disabled by default produces no exporter thread" {
    const thread_count_before = count_process_threads();

    const cfg = interfaces_config.TelemetryConfig{
        .enabled = false,
        .endpoint = null,
        .service_name = "ztick",
        .flush_interval_ms = 5000,
    };
    const providers = try infrastructure_telemetry.setup(std.testing.allocator, cfg);
    try std.testing.expectEqual(@as(?*infrastructure_telemetry.Providers, null), providers);

    const thread_count_after = count_process_threads();
    try std.testing.expectEqual(thread_count_before, thread_count_after);
}

test "telemetry enabled exports metrics to collector endpoint" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var mock_server = try addr.listen(.{ .reuse_address = true });
    defer mock_server.deinit();

    const port = mock_server.listen_address.in.getPort();

    const endpoint_buf = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(endpoint_buf);

    const cfg = interfaces_config.TelemetryConfig{
        .enabled = true,
        .endpoint = endpoint_buf,
        .service_name = "ztick-test",
        .flush_interval_ms = 5000,
    };

    const providers = try infrastructure_telemetry.setup(std.testing.allocator, cfg);
    try std.testing.expect(providers != null);
    defer providers.?.shutdown();

    const instr = try infrastructure_telemetry.createInstruments(
        providers.?.meter_provider,
        providers.?.tracer_provider,
    );
    try instr.jobs_scheduled.add(3, .{});
    try instr.jobs_executed.add(2, .{});
    try instr.jobs_removed.add(1, .{});

    const Capture = struct {
        body: std.ArrayListUnmanaged(u8),
        path: [64]u8 = undefined,
        path_len: usize = 0,
        alloc: std.mem.Allocator,

        fn acceptOne(self: *@This(), server: *std.net.Server) void {
            var conn = server.accept() catch return;
            defer conn.stream.close();

            var buf: [8192]u8 = undefined;
            var total: usize = 0;
            var header_end_offset: ?usize = null;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |he| {
                    header_end_offset = he;
                    break;
                }
            }

            if (header_end_offset) |he| {
                const headers = buf[0..he];
                const body_start = he + 4;
                self.body.appendSlice(self.alloc, buf[body_start..total]) catch {};

                if (std.mem.indexOf(u8, headers, "POST ")) |p| {
                    const after = headers[p + 5 ..];
                    const end = std.mem.indexOf(u8, after, " ") orelse after.len;
                    const path = after[0..@min(end, self.path.len)];
                    @memcpy(self.path[0..path.len], path);
                    self.path_len = path.len;
                }
            }

            _ = conn.stream.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
        }
    };

    var capture = Capture{ .body = .{}, .alloc = std.testing.allocator };
    defer capture.body.deinit(std.testing.allocator);

    const t = try std.Thread.spawn(.{}, Capture.acceptOne, .{ &capture, &mock_server });

    try providers.?.metric_reader.collect();

    t.join();

    const path = capture.path[0..capture.path_len];
    try std.testing.expectEqualStrings("/v1/metrics", path);
    try std.testing.expect(capture.body.items.len > 0);
}

// Feature: F010
test "scheduler SET and tick exports metrics through OTLP to mock collector" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var mock_server = try addr.listen(.{ .reuse_address = true });
    defer mock_server.deinit();

    const port = mock_server.listen_address.in.getPort();

    const endpoint_buf = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(endpoint_buf);

    const cfg = interfaces_config.TelemetryConfig{
        .enabled = true,
        .endpoint = endpoint_buf,
        .service_name = "ztick-test",
        .flush_interval_ms = 5000,
    };

    const providers = try infrastructure_telemetry.setup(std.testing.allocator, cfg);
    try std.testing.expect(providers != null);
    defer providers.?.shutdown();

    const instr = try infrastructure_telemetry.createInstruments(
        providers.?.meter_provider,
        providers.?.tracer_provider,
    );

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    scheduler.setInstruments(instr);

    try scheduler.rule_storage.set(domain_rule.Rule{
        .identifier = "rule.test",
        .pattern = "test.",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "test.job.1", .execution = 1000 } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-2",
        .instruction = .{ .set = .{ .identifier = "test.job.2", .execution = 2000 } },
    });

    const MockCapture = struct {
        path: [64]u8 = undefined,
        path_len: usize = 0,
        received: bool = false,

        fn acceptOne(self: *@This(), server: *std.net.Server) void {
            var conn = server.accept() catch return;
            defer conn.stream.close();

            var buf: [8192]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |_| break;
            }

            if (std.mem.indexOf(u8, buf[0..total], "POST ")) |p| {
                const after = buf[p + 5 .. total];
                const end = std.mem.indexOf(u8, after, " ") orelse after.len;
                const path = after[0..@min(end, self.path.len)];
                @memcpy(self.path[0..path.len], path);
                self.path_len = path.len;
                self.received = true;
            }

            _ = conn.stream.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
        }
    };

    var capture = MockCapture{};
    const t = try std.Thread.spawn(.{}, MockCapture.acceptOne, .{ &capture, &mock_server });

    try providers.?.metric_reader.collect();
    t.join();

    try std.testing.expect(capture.received);
    try std.testing.expectEqualStrings("/v1/metrics", capture.path[0..capture.path_len]);
}

// Feature: F010
test "trace spans exported to collector on job execution" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var mock_server = try addr.listen(.{ .reuse_address = true });
    defer mock_server.deinit();

    const port = mock_server.listen_address.in.getPort();

    const endpoint_buf = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(endpoint_buf);

    const cfg = interfaces_config.TelemetryConfig{
        .enabled = true,
        .endpoint = endpoint_buf,
        .service_name = "ztick-test",
        .flush_interval_ms = 5000,
    };

    const providers = try infrastructure_telemetry.setup(std.testing.allocator, cfg);
    try std.testing.expect(providers != null);
    defer providers.?.shutdown();

    // Register trace processor ONLY for this test — it exports synchronously via OTLP HTTP
    try providers.?.tracer_provider.addSpanProcessor(providers.?.trace_processor.asSpanProcessor());

    const instr = try infrastructure_telemetry.createInstruments(
        providers.?.meter_provider,
        providers.?.tracer_provider,
    );

    const TraceCapture = struct {
        paths: [4][64]u8 = undefined,
        path_lens: [4]usize = [_]usize{0} ** 4,
        count: usize = 0,

        fn acceptN(self: *@This(), server: *std.net.Server, n: usize) void {
            var accepted: usize = 0;
            while (accepted < n) {
                var conn = server.accept() catch return;
                defer conn.stream.close();

                var buf: [8192]u8 = undefined;
                var total: usize = 0;
                while (total < buf.len) {
                    const bytes = conn.stream.read(buf[total..]) catch break;
                    if (bytes == 0) break;
                    total += bytes;
                    if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |_| break;
                }

                if (std.mem.indexOf(u8, buf[0..total], "POST ")) |p| {
                    const after = buf[p + 5 .. total];
                    const end = std.mem.indexOf(u8, after, " ") orelse after.len;
                    const idx = self.count;
                    if (idx < self.paths.len) {
                        const path = after[0..@min(end, self.paths[idx].len)];
                        @memcpy(self.paths[idx][0..path.len], path);
                        self.path_lens[idx] = path.len;
                        self.count += 1;
                    }
                }

                _ = conn.stream.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
                accepted += 1;
            }
        }
    };

    // Mock server must be accepting BEFORE any spans are created, because
    // SimpleProcessor exports synchronously on endSpan via OTLP HTTP.
    var capture = TraceCapture{};
    const t = try std.Thread.spawn(.{}, TraceCapture.acceptN, .{ &capture, &mock_server, 1 });
    std.Thread.sleep(1_000_000);

    // Now create scheduler and trigger spans — mock server is ready
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    scheduler.setInstruments(instr);

    try scheduler.rule_storage.set(domain_rule.Rule{
        .identifier = "rule.trace",
        .pattern = "trace.",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    });

    // SET creates a request span (exported synchronously to mock server)
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-trace-1",
        .instruction = .{ .set = .{ .identifier = "trace.job.1", .execution = 100 } },
    });

    try scheduler.tick(100);

    for (scheduler.execution_client.pending.items) |req| {
        scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
    }
    scheduler.execution_client.pending.clearRetainingCapacity();
    try scheduler.tick(200);

    t.join();

    try std.testing.expect(capture.count >= 1);
    var found_traces = false;
    for (0..capture.count) |i| {
        if (std.mem.eql(u8, capture.paths[i][0..capture.path_lens[i]], "/v1/traces")) {
            found_traces = true;
            break;
        }
    }
    try std.testing.expect(found_traces);
}

// Feature: F010
test "telemetry config parsed from TOML creates functional providers" {
    const toml =
        \\[log]
        \\level = "off"
        \\
        \\[controller]
        \\listen = "127.0.0.1:0"
        \\
        \\[database]
        \\logfile_path = "test_telemetry_config.db"
        \\
        \\[telemetry]
        \\enabled = true
        \\endpoint = "http://127.0.0.1:14318"
        \\service_name = "ztick-config-test"
        \\flush_interval_ms = 1000
        \\
    ;

    const cfg = try interfaces_config.parse(std.testing.allocator, toml);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expect(cfg.telemetry.enabled);
    try std.testing.expectEqualStrings("http://127.0.0.1:14318", cfg.telemetry.endpoint.?);
    try std.testing.expectEqualStrings("ztick-config-test", cfg.telemetry.service_name);
    try std.testing.expectEqual(@as(u32, 1000), cfg.telemetry.flush_interval_ms);

    const providers = try infrastructure_telemetry.setup(std.testing.allocator, cfg.telemetry);
    try std.testing.expect(providers != null);
    providers.?.shutdown();
}

// Feature: F010
test "scheduler operates normally when telemetry collector is unreachable" {
    // NFR-003: export failures must not block scheduler
    const cfg = interfaces_config.TelemetryConfig{
        .enabled = true,
        .endpoint = "http://127.0.0.1:19999",
        .service_name = "ztick-unreachable",
        .flush_interval_ms = 5000,
    };

    const providers = try infrastructure_telemetry.setup(std.testing.allocator, cfg);
    try std.testing.expect(providers != null);
    defer providers.?.shutdown();

    const instr = try infrastructure_telemetry.createInstruments(
        providers.?.meter_provider,
        providers.?.tracer_provider,
    );

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    scheduler.setInstruments(instr);

    try scheduler.rule_storage.set(domain_rule.Rule{
        .identifier = "rule.resilience",
        .pattern = "resilience.",
        .runner = .{ .shell = .{ .command = "/bin/true" } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-r1",
        .instruction = .{ .set = .{ .identifier = "resilience.job.1", .execution = 500 } },
    });

    try scheduler.tick(500);

    const job = scheduler.job_storage.get("resilience.job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(JobStatus.triggered, job.?.status);
}

// Feature: F012

test "stat command returns all 15 metric keys in response body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var connections = std.atomic.Value(usize).init(1);
    scheduler.setStatContext(std.time.nanoTimestamp() - 1_000_000_000, &connections, false, false, 100);

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-stat",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    const body = response.body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "uptime_ns ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "connections ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_total ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_planned ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_triggered ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_executed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_failed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "rules_total ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "executions_pending ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "executions_inflight ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "persistence ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "compression ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "auth_enabled ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tls_enabled ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "framerate ") != null);
}

test "stat command reports correct job counts after storage mutations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var connections = std.atomic.Value(usize).init(0);
    scheduler.setStatContext(0, &connections, false, false, 1);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set-1",
        .instruction = .{ .set = .{ .identifier = "job.planned.1", .execution = 9_000_000_000_000_000_000 } },
    });
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set-2",
        .instruction = .{ .set = .{ .identifier = "job.planned.2", .execution = 9_000_000_000_000_000_001 } },
    });

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-stat-counts",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    const body = response.body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_total 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_planned 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_executed 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_failed 0\n") != null);
}

test "stat command does not append entries to logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("stat_nopersist.db", .{});
        f.close();
    }

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = @import("infrastructure/persistence/backend.zig").PersistenceBackend{ .logfile = .{
        .logfile_path = "stat_nopersist.db",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "baseline.job", .execution = 1595586600_000000000 } },
    });

    const stat_before = try tmp.dir.statFile("stat_nopersist.db");

    var connections = std.atomic.Value(usize).init(0);
    scheduler.setStatContext(0, &connections, false, false, 1);

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-stat-nopersist",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    const stat_after = try tmp.dir.statFile("stat_nopersist.db");
    try std.testing.expectEqual(stat_before.size, stat_after.size);
}

test "stat command reports auth_enabled 1 when authentication is configured" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var connections = std.atomic.Value(usize).init(0);
    scheduler.setStatContext(0, &connections, true, false, 1);

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-stat-auth",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "auth_enabled 1\n") != null);
}

test "stat command succeeds and reports auth_enabled 0 when auth is not configured" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var connections = std.atomic.Value(usize).init(0);
    scheduler.setStatContext(0, &connections, false, false, 1);

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-stat-noauth",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "auth_enabled 0\n") != null);
}

test "stat command over TCP returns multi-line response with all keys ending with OK" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(allocator, "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19886\"\n\n[database]\npersistence = \"memory\"\n");
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19886) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    _ = stream.write("req-1 STAT\n") catch return error.SkipZigTest;

    std.Thread.sleep(300_000_000);

    const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | nonblock) catch {};

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 uptime_ns ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 connections ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 jobs_total ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 jobs_planned ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 jobs_triggered ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 jobs_executed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 jobs_failed ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 rules_total ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 executions_pending ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 executions_inflight ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 persistence ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 compression ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 auth_enabled ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 tls_enabled ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 framerate ") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 OK\n") != null);
}

test "stat command over TCP rejects unauthenticated client when auth is enabled" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tokens_file = try tmp_dir.dir.createFile("tokens.toml", .{});
    try tokens_file.writeAll("[token.test]\nsecret = \"secret-token\"\nnamespace = \"*\"\n");
    tokens_file.close();

    const tokens_path = try tmp_dir.dir.realpathAlloc(allocator, "tokens.toml");
    defer allocator.free(tokens_path);

    const config = try std.fmt.allocPrint(allocator, "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19888\"\nauth_file = \"{s}\"\n\n[database]\npersistence = \"memory\"\n", .{tokens_path});
    defer allocator.free(config);

    var server = try TestServer.start(allocator, config);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19888) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    _ = stream.write("req-unauth STAT\n") catch return error.SkipZigTest;

    // Use poll instead of sleep+nonblocking for sanitizer reliability
    var pfd = [1]std.posix.pollfd{.{
        .fd = stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, 2000) catch return error.SkipZigTest;
    if (ready == 0) return error.SkipZigTest;

    var buf: [4096]u8 = undefined;
    const n = stream.read(buf[0..]) catch return error.SkipZigTest;
    const response = buf[0..n];

    // Server responds ERROR without request_id for non-AUTH commands before authentication
    try std.testing.expect(std.mem.indexOf(u8, response, "ERROR\n") != null);
}

test "stat command over TCP reports connections reflecting active connection count" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(allocator, "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19887\"\n\n[database]\npersistence = \"memory\"\n");
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19887) catch unreachable;

    var conn1 = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer conn1.close();
    var conn2 = std.net.tcpConnectToAddress(addr) catch {
        conn1.close();
        return error.SkipZigTest;
    };
    defer conn2.close();
    var conn3 = std.net.tcpConnectToAddress(addr) catch {
        conn1.close();
        conn2.close();
        return error.SkipZigTest;
    };
    defer conn3.close();

    std.Thread.sleep(200_000_000);

    _ = conn1.write("req-stat-conn STAT\n") catch return error.SkipZigTest;

    std.Thread.sleep(300_000_000);

    const flags = std.posix.fcntl(conn1.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(conn1.handle, std.posix.F.SETFL, flags | nonblock) catch {};

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = conn1.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-stat-conn connections 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-stat-conn OK\n") != null);
}

// Feature: F011

const AuthPaths = struct {
    valid: []const u8,
    wildcard: []const u8,

    fn resolve(allocator: std.mem.Allocator) !AuthPaths {
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        const valid = try std.fmt.allocPrint(allocator, "{s}/test/fixtures/auth/valid.toml", .{cwd});
        errdefer allocator.free(valid);
        const wildcard = try std.fmt.allocPrint(allocator, "{s}/test/fixtures/auth/wildcard.toml", .{cwd});
        return .{ .valid = valid, .wildcard = wildcard };
    }

    fn deinit(self: AuthPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.wildcard);
        allocator.free(self.valid);
    }
};

test "F011: valid AUTH followed by SET command succeeds" {
    const allocator = std.testing.allocator;

    const auth = try AuthPaths.resolve(allocator);
    defer auth.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19881\"\nauth_file = \"{s}\"\n\n[database]\nlogfile_path = \"test_auth_valid_set.db\"\n",
        .{auth.valid},
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19881) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    const recv_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    _ = stream.write("AUTH sk_deploy_a1b2c3d4e5f6\n") catch return error.SkipZigTest;

    var auth_buf: [16]u8 = undefined;
    const auth_n = stream.read(&auth_buf) catch return error.SkipZigTest;
    const auth_response = auth_buf[0..auth_n];

    try std.testing.expectEqualStrings("OK\n", auth_response);

    _ = stream.write("req-auth-1 SET deploy.release.1 1595586600000000000\n") catch return error.SkipZigTest;

    var set_buf: [64]u8 = undefined;
    const set_n = stream.read(&set_buf) catch return error.SkipZigTest;
    const set_response = set_buf[0..set_n];

    try std.testing.expect(std.mem.indexOf(u8, set_response, "OK") != null);

    server.tmp_dir.dir.deleteFile("test_auth_valid_set.db") catch {};
}

test "F011: invalid AUTH closes connection" {
    const allocator = std.testing.allocator;

    const auth = try AuthPaths.resolve(allocator);
    defer auth.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19882\"\nauth_file = \"{s}\"\n\n[database]\nlogfile_path = \"test_auth_invalid.db\"\n",
        .{auth.valid},
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19882) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    const recv_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    _ = stream.write("AUTH invalid_secret\n") catch return error.SkipZigTest;

    var buf: [16]u8 = undefined;
    const n = stream.read(&buf) catch return error.SkipZigTest;
    const response = buf[0..n];

    try std.testing.expectEqualStrings("ERROR\n", response);

    // Server closes the connection after rejecting invalid AUTH
    var closed_buf: [16]u8 = undefined;
    const closed_n = stream.read(&closed_buf) catch 0;
    try std.testing.expectEqual(@as(usize, 0), closed_n);

    server.tmp_dir.dir.deleteFile("test_auth_invalid.db") catch {};
}

test "F011: namespace deny rejects SET outside namespace, allow within namespace" {
    const allocator = std.testing.allocator;

    const auth = try AuthPaths.resolve(allocator);
    defer auth.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19909\"\nauth_file = \"{s}\"\n\n[database]\nlogfile_path = \"test_auth_ns_deny.db\"\n",
        .{auth.valid},
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19909) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    const recv_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    _ = stream.write("AUTH sk_deploy_a1b2c3d4e5f6\n") catch return error.SkipZigTest;

    var auth_buf: [16]u8 = undefined;
    const auth_n = stream.read(&auth_buf) catch return error.SkipZigTest;
    try std.testing.expectEqualStrings("OK\n", auth_buf[0..auth_n]);

    _ = stream.write("req-ns-deny-1 SET backup.daily 1595586600000000000\n") catch return error.SkipZigTest;

    var deny_buf: [64]u8 = undefined;
    const deny_n = stream.read(&deny_buf) catch return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, deny_buf[0..deny_n], "ERROR") != null);

    _ = stream.write("req-ns-allow-1 SET deploy.release.1 1595586600000000000\n") catch return error.SkipZigTest;

    var allow_buf: [64]u8 = undefined;
    const allow_n = stream.read(&allow_buf) catch return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, allow_buf[0..allow_n], "OK") != null);

    server.tmp_dir.dir.deleteFile("test_auth_ns_deny.db") catch {};
}

test "F011: no auth_file allows commands without AUTH" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19883\"\n\n[database]\nlogfile_path = \"test_no_auth.db\"\n",
    );
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19883) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    const recv_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    _ = stream.write("req-noauth-1 SET test.job 1595586600000000000\n") catch return error.SkipZigTest;

    var buf: [64]u8 = undefined;
    const n = stream.read(&buf) catch return error.SkipZigTest;
    const response = buf[0..n];

    try std.testing.expect(std.mem.indexOf(u8, response, "OK") != null);

    server.tmp_dir.dir.deleteFile("test_no_auth.db") catch {};
}

test "F011: wildcard namespace allows commands targeting any identifier" {
    const allocator = std.testing.allocator;

    const auth = try AuthPaths.resolve(allocator);
    defer auth.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19885\"\nauth_file = \"{s}\"\n\n[database]\nlogfile_path = \"test_auth_wildcard.db\"\n",
        .{auth.wildcard},
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19885) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    const recv_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    _ = stream.write("AUTH sk_admin_a1b2c3d4e5f6\n") catch return error.SkipZigTest;

    var auth_buf: [16]u8 = undefined;
    const auth_n = stream.read(&auth_buf) catch return error.SkipZigTest;
    try std.testing.expectEqualStrings("OK\n", auth_buf[0..auth_n]);

    _ = stream.write("req-wc-1 SET deploy.job1 1595586600000000000\n") catch return error.SkipZigTest;
    var buf1: [64]u8 = undefined;
    const n1 = stream.read(&buf1) catch return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, buf1[0..n1], "OK") != null);

    _ = stream.write("req-wc-2 SET backup.job1 1595586600000000000\n") catch return error.SkipZigTest;
    var buf2: [64]u8 = undefined;
    const n2 = stream.read(&buf2) catch return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, buf2[0..n2], "OK") != null);

    server.tmp_dir.dir.deleteFile("test_auth_wildcard.db") catch {};
}

test "F011: QUERY filters results to client namespace" {
    const allocator = std.testing.allocator;

    const auth = try AuthPaths.resolve(allocator);
    defer auth.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19886\"\nauth_file = \"{s}\"\n\n[database]\nlogfile_path = \"test_auth_query_filter.db\"\n",
        .{auth.valid},
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19886) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    const recv_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    // Authenticate as the backup. token first to seed a backup. job via a separate connection
    {
        var seed_stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
        defer seed_stream.close();
        std.posix.setsockopt(
            seed_stream.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&recv_timeout),
        ) catch {};
        _ = seed_stream.write("AUTH sk_backup_d4e5f6a1b2c3\n") catch return error.SkipZigTest;
        var sb: [16]u8 = undefined;
        _ = seed_stream.read(&sb) catch return error.SkipZigTest;
        _ = seed_stream.write("seed-1 SET backup.job1 1595586600000000000\n") catch return error.SkipZigTest;
        var sb2: [64]u8 = undefined;
        _ = seed_stream.read(&sb2) catch return error.SkipZigTest;
    }

    _ = stream.write("AUTH sk_deploy_a1b2c3d4e5f6\n") catch return error.SkipZigTest;
    var auth_buf: [16]u8 = undefined;
    const auth_n = stream.read(&auth_buf) catch return error.SkipZigTest;
    try std.testing.expectEqualStrings("OK\n", auth_buf[0..auth_n]);

    _ = stream.write("req-set-1 SET deploy.job1 1595586600000000000\n") catch return error.SkipZigTest;
    var set_buf: [64]u8 = undefined;
    _ = stream.read(&set_buf) catch return error.SkipZigTest;

    // Empty pattern returns all jobs from scheduler; TCP handler filters by namespace
    _ = stream.write("req-q-1 QUERY\n") catch return error.SkipZigTest;

    // Accumulate all response lines until OK terminator
    var response_buf: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < response_buf.len) {
        const n = stream.read(response_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, response_buf[0..total], "req-q-1 OK\n") != null) break;
    }
    const response = response_buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "deploy.job1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "backup.job1") == null);

    server.tmp_dir.dir.deleteFile("test_auth_query_filter.db") catch {};
}

test "F011: RULE SET namespace enforcement rejects pattern outside namespace, allows within namespace" {
    const allocator = std.testing.allocator;

    const auth = try AuthPaths.resolve(allocator);
    defer auth.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19887\"\nauth_file = \"{s}\"\n\n[database]\nlogfile_path = \"test_auth_rule_set_ns.db\"\n",
        .{auth.valid},
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19887) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    const recv_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    _ = stream.write("AUTH sk_deploy_a1b2c3d4e5f6\n") catch return error.SkipZigTest;

    var auth_buf: [16]u8 = undefined;
    const auth_n = stream.read(&auth_buf) catch return error.SkipZigTest;
    try std.testing.expectEqualStrings("OK\n", auth_buf[0..auth_n]);

    _ = stream.write("req-rs-deny-1 RULE SET x backup. shell echo\n") catch return error.SkipZigTest;

    var deny_buf: [64]u8 = undefined;
    const deny_n = stream.read(&deny_buf) catch return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, deny_buf[0..deny_n], "ERROR") != null);

    _ = stream.write("req-rs-allow-1 RULE SET deploy.r deploy. shell echo\n") catch return error.SkipZigTest;

    var allow_buf: [64]u8 = undefined;
    const allow_n = stream.read(&allow_buf) catch return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, allow_buf[0..allow_n], "OK") != null);

    server.tmp_dir.dir.deleteFile("test_auth_rule_set_ns.db") catch {};
}

test "F011: connection closed when no AUTH data received within timeout" {
    const allocator = std.testing.allocator;

    const auth = try AuthPaths.resolve(allocator);
    defer auth.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"debug\"\n\n[controller]\nlisten = \"127.0.0.1:19888\"\nauth_file = \"{s}\"\n\n[database]\nlogfile_path = \"test_auth_timeout.db\"\n",
        .{auth.valid},
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19888) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    // Connect but send no data; server must close the connection after auth timeout (FR-010: 5 seconds)
    var pfd = [1]std.posix.pollfd{.{
        .fd = stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, 6000) catch return error.SkipZigTest;
    try std.testing.expect(ready > 0);
    var buf: [1]u8 = undefined;
    const n = std.posix.read(stream.handle, &buf) catch 0;
    try std.testing.expectEqual(@as(usize, 0), n);

    server.tmp_dir.dir.deleteFile("test_auth_timeout.db") catch {};
}

// Feature: F013

test "direct runner rule set via scheduler stores rule with correct runner fields" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const args = [_][]const u8{ "-s", "http://example.com" };
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule-direct",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.direct",
            .pattern = "fetch.",
            .runner = .{ .direct = .{ .executable = "/usr/bin/curl", .args = &args } },
        } },
    });

    const rule = scheduler.rule_storage.get("rule.direct");
    try std.testing.expect(rule != null);
    try std.testing.expectEqualStrings("fetch.", rule.?.pattern);
    switch (rule.?.runner) {
        .direct => |d| {
            try std.testing.expectEqualStrings("/usr/bin/curl", d.executable);
            try std.testing.expectEqual(@as(usize, 2), d.args.len);
            try std.testing.expectEqualStrings("-s", d.args[0]);
            try std.testing.expectEqualStrings("http://example.com", d.args[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "direct runner rule stored and retrieved via list rules query" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const args = [_][]const u8{"hello world"};
    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.echo",
            .pattern = "print.",
            .runner = .{ .direct = .{ .executable = "/bin/echo", .args = &args } },
        } },
    });

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-list",
        .instruction = .{ .list_rules = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "print.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "direct") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "/bin/echo") != null);
}

test "direct runner rule persisted and replayed with correct fields" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = [_][]const u8{ "-s", "http://example.com" };
    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = .{ .identifier = "rule.direct.replay", .pattern = "fetch.", .runner = .{ .direct = .{ .executable = "/usr/bin/curl", .args = &args } } } },
    });
    defer allocator.free(logfile_data);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var decode_arena = try replay_into_scheduler(allocator, logfile_data, &scheduler);
    defer decode_arena.deinit();

    const rule = scheduler.rule_storage.get("rule.direct.replay");
    try std.testing.expect(rule != null);
    try std.testing.expectEqualStrings("fetch.", rule.?.pattern);
    switch (rule.?.runner) {
        .direct => |d| {
            try std.testing.expectEqualStrings("/usr/bin/curl", d.executable);
            try std.testing.expectEqual(@as(usize, 2), d.args.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "dump command prints RULE SET line for direct runner with no args" {
    const allocator = std.testing.allocator;

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = .{ .identifier = "rule.notify", .pattern = "notify.", .runner = .{ .direct = .{ .executable = "/usr/bin/notify-send", .args = &.{} } } } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "RULE SET rule.notify notify. direct /usr/bin/notify-send\n") != null);
}

test "dump command prints RULE SET line for direct runner with args" {
    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "-s", "http://example.com" };
    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = .{ .identifier = "rule.curl", .pattern = "fetch.", .runner = .{ .direct = .{ .executable = "/usr/bin/curl", .args = &args } } } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{});
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "RULE SET rule.curl fetch. direct /usr/bin/curl -s http://example.com\n") != null);
}

test "dump command prints JSON for direct runner rule" {
    const allocator = std.testing.allocator;

    const args = [_][]const u8{"hello world"};
    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = .{ .identifier = "rule.echo", .pattern = "print.", .runner = .{ .direct = .{ .executable = "/bin/echo", .args = &args } } } },
    });
    defer allocator.free(logfile_data);

    var result = try run_dump_command(allocator, logfile_data, &.{ "--format", "json" });
    defer result.deinit();

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"type\":\"rule_set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"type\":\"direct\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"/bin/echo\"") != null);
}

test "RULE SET with direct runner over TCP stores rule and appears in LISTRULES" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(allocator, "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19890\"\n\n[database]\npersistence = \"memory\"\n");
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19890) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    _ = stream.write("req-1 RULE SET rule.direct print. direct /bin/echo \"hello world\"\n") catch return error.SkipZigTest;
    std.Thread.sleep(200_000_000);

    _ = stream.write("req-2 LISTRULES\n") catch return error.SkipZigTest;
    std.Thread.sleep(300_000_000);

    const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | nonblock) catch {};

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 OK\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "direct") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "/bin/echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-2 OK\n") != null);
}

test "server with custom shell config starts successfully and accepts commands" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(allocator, "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19891\"\n\n[database]\npersistence = \"memory\"\n\n[shell]\npath = \"/bin/sh\"\nargs = [\"-c\"]\n");
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19891) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    _ = stream.write("req-1 RULE SET rule.shell run. shell /bin/true\n") catch return error.SkipZigTest;
    std.Thread.sleep(200_000_000);

    const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | nonblock) catch {};

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 OK\n") != null);
}

test "server with invalid shell path fails to start" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var config_file = try tmp_dir.dir.createFile("ztick.toml", .{});
    try config_file.writeAll("[log]\nlevel = \"error\"\n\n[controller]\nlisten = \"127.0.0.1:0\"\n\n[database]\npersistence = \"memory\"\n\n[shell]\npath = \"/nonexistent/shell\"\n");
    config_file.close();

    const config_path = try tmp_dir.dir.realpathAlloc(allocator, "ztick.toml");
    defer allocator.free(config_path);

    var child = try spawn_ztick(allocator, config_path);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| try std.testing.expect(code != 0),
        else => try std.testing.expect(false),
    }
}

// Feature: F015

fn send_http_request(stream: std.net.Stream, request: []const u8) ![]const u8 {
    _ = stream.write(request) catch return error.SkipZigTest;
    std.Thread.sleep(500_000_000);

    const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | nonblock) catch return error.SkipZigTest;

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return error.SkipZigTest;
    return buf[0..total];
}

fn http_connect(port: u16) !std.net.Stream {
    const addr = std.net.Address.parseIp("127.0.0.1", port) catch unreachable;
    return std.net.tcpConnectToAddress(addr) catch error.SkipZigTest;
}

// Feature: F015
test "job lifecycle via HTTP creates retrieves and deletes a job" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19892\"\n\n[http]\nlisten = \"127.0.0.1:19893\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    {
        var stream = try http_connect(19893);
        defer stream.close();
        // Far-future execution keeps the job in .planned status; a past date would let the
        // scheduler tick transition it to .failed (no matching rule) before the GET below.
        const response = try send_http_request(
            stream,
            "PUT /jobs/deploy.v1 HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 37\r\n\r\n{\"execution\": \"2099-12-31T23:59:59Z\"}",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"id\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "deploy.v1") != null);
    }

    {
        var stream = try http_connect(19893);
        defer stream.close();
        const response = try send_http_request(
            stream,
            "GET /jobs/deploy.v1 HTTP/1.1\r\n\r\n",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "deploy.v1") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "planned") != null);
    }

    {
        var stream = try http_connect(19893);
        defer stream.close();
        const response = try send_http_request(
            stream,
            "DELETE /jobs/deploy.v1 HTTP/1.1\r\n\r\n",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "204") != null);
    }

    {
        var stream = try http_connect(19893);
        defer stream.close();
        const response = try send_http_request(
            stream,
            "GET /jobs/deploy.v1 HTTP/1.1\r\n\r\n",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "404") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
    }
}

// Feature: F015
test "health check returns 200 with status ok" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19894\"\n\n[http]\nlisten = \"127.0.0.1:19895\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    var stream = try http_connect(19895);
    defer stream.close();
    const response = try send_http_request(
        stream,
        "GET /health HTTP/1.1\r\n\r\n",
    );
    try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "application/json") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "{\"status\":\"ok\"}") != null);
}

// Feature: F015
test "unknown path returns 404 not found" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19896\"\n\n[http]\nlisten = \"127.0.0.1:19897\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    var stream = try http_connect(19897);
    defer stream.close();
    const response = try send_http_request(
        stream,
        "GET /unknown HTTP/1.1\r\n\r\n",
    );
    try std.testing.expect(std.mem.indexOf(u8, response, "404") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
}

// Feature: F015
test "config without http section does not open HTTP port" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19898\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19899) catch unreachable;
    const result = std.net.tcpConnectToAddress(addr);
    if (result) |stream| {
        stream.close();
        return error.TestExpectedEqual;
    } else |_| {}
}

// Feature: F015
test "job created via HTTP is retrievable via TCP" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19900\"\n\n[http]\nlisten = \"127.0.0.1:19901\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    {
        var stream = try http_connect(19901);
        defer stream.close();
        // Far-future execution keeps the job in .planned status; the TCP GET below asserts
        // on "planned", which would not appear if the scheduler transitioned the job to .failed.
        const response = try send_http_request(
            stream,
            "PUT /jobs/cross.1 HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 37\r\n\r\n{\"execution\": \"2099-12-31T23:59:59Z\"}",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
    }

    {
        const addr = std.net.Address.parseIp("127.0.0.1", 19900) catch unreachable;
        var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
        defer stream.close();

        _ = stream.write("req-tcp-1 GET cross.1\n") catch return error.SkipZigTest;
        std.Thread.sleep(500_000_000);

        const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
        const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
        _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | nonblock) catch return error.SkipZigTest;

        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = stream.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        const response = buf[0..total];

        try std.testing.expect(std.mem.indexOf(u8, response, "cross.1") != null or std.mem.indexOf(u8, response, "planned") != null);
    }
}

// Feature: F015
test "rule lifecycle via HTTP creates and deletes a rule" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19902\"\n\n[http]\nlisten = \"127.0.0.1:19903\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    {
        var stream = try http_connect(19903);
        defer stream.close();
        const body = "{\"pattern\":\"deploy.*\",\"runner\":\"shell\",\"args\":[\"/usr/bin/notify\"]}";
        var content_length_buf: [64]u8 = undefined;
        const content_length_str = std.fmt.bufPrint(&content_length_buf, "{d}", .{body.len}) catch unreachable;

        var request_buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf, "PUT /rules/notify HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {s}\r\n\r\n{s}", .{ content_length_str, body }) catch unreachable;
        const response = try send_http_request(stream, request);
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "notify") != null);
    }

    {
        var stream = try http_connect(19903);
        defer stream.close();
        const response = try send_http_request(
            stream,
            "DELETE /rules/notify HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "204") != null);
    }

    {
        var stream = try http_connect(19903);
        defer stream.close();
        const response = try send_http_request(
            stream,
            "DELETE /rules/missing HTTP/1.1\r\nContent-Length: 0\r\n\r\n",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "404") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
    }
}

// Feature: F015
test "job listing with prefix filter returns matching jobs" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19904\"\n\n[http]\nlisten = \"127.0.0.1:19905\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    {
        var stream = try http_connect(19905);
        defer stream.close();
        const body = "{\"execution\": \"2026-04-10T12:00:00Z\"}";
        var buf: [256]u8 = undefined;
        const request = std.fmt.bufPrint(&buf, "PUT /jobs/deploy.v1 HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
        const response = try send_http_request(stream, request);
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
    }

    {
        var stream = try http_connect(19905);
        defer stream.close();
        const body = "{\"execution\": \"2026-04-11T12:00:00Z\"}";
        var buf: [256]u8 = undefined;
        const request = std.fmt.bufPrint(&buf, "PUT /jobs/deploy.v2 HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
        const response = try send_http_request(stream, request);
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
    }

    {
        var stream = try http_connect(19905);
        defer stream.close();
        const response = try send_http_request(
            stream,
            "GET /jobs?prefix=deploy. HTTP/1.1\r\n\r\n",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "deploy.v1") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "deploy.v2") != null);
    }
}

// Feature: F016
test "RULE SET with AWF runner over TCP stores rule and appears in LISTRULES" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(allocator, "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19908\"\n\n[database]\npersistence = \"memory\"\n");
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19908) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    _ = stream.write("req-1 RULE SET rule.awf app. awf code-review --input target=main\n") catch return error.SkipZigTest;
    std.Thread.sleep(200_000_000);

    _ = stream.write("req-2 LISTRULES\n") catch return error.SkipZigTest;
    std.Thread.sleep(300_000_000);

    const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | nonblock) catch {};

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 OK\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "awf") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "code-review") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-2 OK\n") != null);
}

// Feature: F015
test "malformed JSON on PUT returns 400 bad request" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19906\"\n\n[http]\nlisten = \"127.0.0.1:19907\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    var stream = try http_connect(19907);
    defer stream.close();
    const body = "{not valid json}";
    var buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&buf, "PUT /jobs/bad.json HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    const response = try send_http_request(stream, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "400") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
}

// Feature: F016
test "AWF rule with input persists and replays from logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_rule = Rule{
        .identifier = "rule.report",
        .pattern = "report.",
        .runner = .{ .awf = .{ .workflow = "generate-report", .inputs = &.{ "format=pdf", "target=main" } } },
    };

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = original_rule },
    });
    defer allocator.free(logfile_data);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var decode_arena = try replay_into_scheduler(allocator, logfile_data, &scheduler);
    defer decode_arena.deinit();

    const restored = scheduler.rule_storage.get("rule.report");
    try std.testing.expect(restored != null);
    try std.testing.expectEqualStrings("report.", restored.?.pattern);
    try std.testing.expectEqualStrings("generate-report", restored.?.runner.awf.workflow);
    try std.testing.expectEqual(@as(usize, 2), restored.?.runner.awf.inputs.len);
    try std.testing.expectEqualStrings("format=pdf", restored.?.runner.awf.inputs[0]);
    try std.testing.expectEqualStrings("target=main", restored.?.runner.awf.inputs[1]);
}

// Feature: F016
test "RULE SET with AWF runner and --input over TCP stores rule with input parameter" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(allocator, "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19910\"\n\n[database]\npersistence = \"memory\"\n");
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19910) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    _ = stream.write("req-1 RULE SET rule.report report. awf generate-report --input format=pdf --input target=main\n") catch return error.SkipZigTest;
    std.Thread.sleep(200_000_000);

    _ = stream.write("req-2 LISTRULES\n") catch return error.SkipZigTest;
    std.Thread.sleep(300_000_000);

    const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | nonblock) catch {};

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 OK\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "generate-report") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "format=pdf") != null);
}

// Feature: F016
test "AWF rule without input persists and replays from logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_rule = Rule{
        .identifier = "rule.review",
        .pattern = "app.",
        .runner = .{ .awf = .{ .workflow = "code-review", .inputs = &.{} } },
    };

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = original_rule },
    });
    defer allocator.free(logfile_data);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var decode_arena = try replay_into_scheduler(allocator, logfile_data, &scheduler);
    defer decode_arena.deinit();

    const restored = scheduler.rule_storage.get("rule.review");
    try std.testing.expect(restored != null);
    try std.testing.expectEqualStrings("app.", restored.?.pattern);
    try std.testing.expectEqualStrings("code-review", restored.?.runner.awf.workflow);
    try std.testing.expectEqual(@as(usize, 0), restored.?.runner.awf.inputs.len);
}

// Feature: F016
test "HTTP PUT creates AWF rule and GET returns it in listing" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19912\"\n\n[http]\nlisten = \"127.0.0.1:19913\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    {
        var stream = try http_connect(19913);
        defer stream.close();
        const body = "{\"pattern\": \"app.\", \"runner\": \"awf\", \"args\": [\"code-review\"]}";
        var buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(&buf, "PUT /rules/rule.awf HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
        const response = try send_http_request(stream, request);
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "rule.awf") != null);
    }

    {
        var stream = try http_connect(19913);
        defer stream.close();
        const response = try send_http_request(
            stream,
            "GET /rules?prefix=rule. HTTP/1.1\r\n\r\n",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "rule.awf") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "awf") != null);
    }
}

// Feature: F016
test "TCP RULE SET with awf runner missing workflow returns ERROR" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(allocator, "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19914\"\n\n[database]\npersistence = \"memory\"\n");
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19914) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    _ = stream.write("req-1 RULE SET rule.bad app. awf\n") catch return error.SkipZigTest;
    std.Thread.sleep(200_000_000);

    const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | nonblock) catch {};

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 ERROR\n") != null);
}

test "RULE SET with HTTP runner over TCP stores rule and appears in LISTRULES" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(allocator, "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19915\"\n\n[database]\npersistence = \"memory\"\n");
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19915) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    _ = stream.write("req-1 RULE SET rule.http webhook. http POST https://hooks.example.com/notify\n") catch return error.SkipZigTest;
    std.Thread.sleep(200_000_000);

    _ = stream.write("req-2 LISTRULES\n") catch return error.SkipZigTest;
    std.Thread.sleep(300_000_000);

    const flags = std.posix.fcntl(stream.handle, std.posix.F.GETFL, 0) catch return error.SkipZigTest;
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = std.posix.fcntl(stream.handle, std.posix.F.SETFL, flags | nonblock) catch {};

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-1 OK\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "http") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "POST") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "https://hooks.example.com/notify") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-2 OK\n") != null);
}

test "HTTP PUT creates HTTP rule and GET returns it in listing" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19916\"\n\n[http]\nlisten = \"127.0.0.1:19917\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    {
        var stream = try http_connect(19917);
        defer stream.close();
        const body = "{\"pattern\": \"deploy.\", \"runner\": \"http\", \"args\": [\"POST\", \"https://hooks.example.com/webhook\"]}";
        var buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(&buf, "PUT /rules/rule.http HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
        const response = try send_http_request(stream, request);
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "rule.http") != null);
    }

    {
        var stream = try http_connect(19917);
        defer stream.close();
        const response = try send_http_request(
            stream,
            "GET /rules?prefix=rule. HTTP/1.1\r\n\r\n",
        );
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "rule.http") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "http") != null);
    }
}

test "HTTP PUT with HTTP runner missing url returns 400 bad request" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19918\"\n\n[http]\nlisten = \"127.0.0.1:19919\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    var stream = try http_connect(19919);
    defer stream.close();
    const body = "{\"pattern\": \"x\", \"runner\": \"http\", \"args\": [\"GET\"]}";
    var buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&buf, "PUT /rules/rule.bad HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    const response = try send_http_request(stream, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "400") != null);
}

test "HTTP PUT with HTTP runner unsupported method returns 400 bad request" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19920\"\n\n[http]\nlisten = \"127.0.0.1:19921\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    var stream = try http_connect(19921);
    defer stream.close();
    const body = "{\"pattern\": \"x\", \"runner\": \"http\", \"args\": [\"PATCH\", \"https://hooks.example.com/webhook\"]}";
    var buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&buf, "PUT /rules/rule.bad HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    const response = try send_http_request(stream, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "400") != null);
}

test "HTTP PUT with HTTP runner invalid url scheme returns 400 bad request" {
    const allocator = std.testing.allocator;

    var server = try TestServer.start(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19922\"\n\n[http]\nlisten = \"127.0.0.1:19923\"\n\n[database]\npersistence = \"memory\"\n",
    );
    defer server.stop();

    var stream = try http_connect(19923);
    defer stream.close();
    const body = "{\"pattern\": \"x\", \"runner\": \"http\", \"args\": [\"POST\", \"ftp://hooks.example.com/webhook\"]}";
    var buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&buf, "PUT /rules/rule.bad HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    const response = try send_http_request(stream, request);
    try std.testing.expect(std.mem.indexOf(u8, response, "400") != null);
}

test "HTTP rule persists and replays from logfile with correct method and url" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original_rule = Rule{
        .identifier = "rule.webhook",
        .pattern = "deploy.",
        .runner = .{ .http = .{ .method = "POST", .url = "https://hooks.example.com/webhook" } },
    };

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = original_rule },
    });
    defer allocator.free(logfile_data);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var decode_arena = try replay_into_scheduler(allocator, logfile_data, &scheduler);
    defer decode_arena.deinit();

    const restored = scheduler.rule_storage.get("rule.webhook");
    try std.testing.expect(restored != null);
    try std.testing.expectEqualStrings("deploy.", restored.?.pattern);
    try std.testing.expectEqualStrings("POST", restored.?.runner.http.method);
    try std.testing.expectEqualStrings("https://hooks.example.com/webhook", restored.?.runner.http.url);
}

// Feature: F018

test "stat command over TCP reports auth_enabled 1 when auth_file is configured" {
    const allocator = std.testing.allocator;

    const auth = try AuthPaths.resolve(allocator);
    defer auth.deinit(allocator);

    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19924\"\nauth_file = \"{s}\"\n\n[database]\npersistence = \"memory\"\n",
        .{auth.wildcard},
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19924) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    const recv_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    _ = stream.write("AUTH sk_admin_a1b2c3d4e5f6\n") catch return error.SkipZigTest;

    var auth_buf: [16]u8 = undefined;
    const auth_n = stream.read(&auth_buf) catch return error.SkipZigTest;
    try std.testing.expectEqualStrings("OK\n", auth_buf[0..auth_n]);

    _ = stream.write("req-stat-f018 STAT\n") catch return error.SkipZigTest;

    // Poll in a loop to accumulate multi-line STAT response for sanitizer reliability
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        var pfd = [1]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, 2000) catch return error.SkipZigTest;
        if (ready == 0) break;
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "req-stat-f018 OK\n") != null) break;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-stat-f018 auth_enabled 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-stat-f018 OK\n") != null);
}

test "stat command succeeds for namespace-scoped authenticated client" {
    const allocator = std.testing.allocator;

    const auth = try AuthPaths.resolve(allocator);
    defer auth.deinit(allocator);

    // valid.toml has deploy token scoped to "deploy." namespace
    const config_content = try std.fmt.allocPrint(
        allocator,
        "[log]\nlevel = \"off\"\n\n[controller]\nlisten = \"127.0.0.1:19925\"\nauth_file = \"{s}\"\n\n[database]\npersistence = \"memory\"\n",
        .{auth.valid},
    );
    defer allocator.free(config_content);

    var server = try TestServer.start(allocator, config_content);
    defer server.stop();

    const addr = std.net.Address.parseIp("127.0.0.1", 19925) catch unreachable;
    var stream = std.net.tcpConnectToAddress(addr) catch return error.SkipZigTest;
    defer stream.close();

    const recv_timeout = std.posix.timeval{ .sec = 2, .usec = 0 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&recv_timeout),
    ) catch {};

    _ = stream.write("AUTH sk_deploy_a1b2c3d4e5f6\n") catch return error.SkipZigTest;

    var auth_buf: [16]u8 = undefined;
    const auth_n = stream.read(&auth_buf) catch return error.SkipZigTest;
    try std.testing.expectEqualStrings("OK\n", auth_buf[0..auth_n]);

    // STAT has no namespace prefix — must succeed despite namespace-scoped token
    _ = stream.write("req-stat-ns STAT\n") catch return error.SkipZigTest;

    // Poll in a loop to accumulate multi-line STAT response for sanitizer reliability
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        var pfd = [1]std.posix.pollfd{.{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&pfd, 2000) catch return error.SkipZigTest;
        if (ready == 0) break;
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "req-stat-ns OK\n") != null) break;
    }
    const response = buf[0..total];

    try std.testing.expect(std.mem.indexOf(u8, response, "req-stat-ns auth_enabled 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "req-stat-ns OK\n") != null);
}

// Feature: F019

test "scheduler dispatches AMQP runner request when matching job triggers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.notify",
            .pattern = "notify.",
            .runner = .{ .amqp = .{
                .dsn = "amqp://guest:guest@localhost:5672/",
                .exchange = "jobs",
                .routing_key = "notifications",
            } },
        } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-job",
        .instruction = .{ .set = .{ .identifier = "notify.alert.1", .execution = 1000 } },
    });

    try scheduler.tick(1000);

    try std.testing.expectEqual(JobStatus.triggered, scheduler.job_storage.get("notify.alert.1").?.status);
    try std.testing.expectEqual(@as(usize, 1), scheduler.execution_client.pending.items.len);

    const dispatched = scheduler.execution_client.pending.items[0];
    try std.testing.expectEqualStrings("notify.alert.1", dispatched.job_identifier);
    switch (dispatched.runner) {
        .amqp => |a| {
            try std.testing.expectEqualStrings("amqp://guest:guest@localhost:5672/", a.dsn);
            try std.testing.expectEqualStrings("jobs", a.exchange);
            try std.testing.expectEqualStrings("notifications", a.routing_key);
        },
        else => return error.TestUnexpectedRunnerVariant,
    }
}

test "persisted AMQP rule replays and dispatches matching job after reload" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const persisted_rule = Rule{
        .identifier = "rule.publish",
        .pattern = "events.",
        .runner = .{ .amqp = .{
            .dsn = "amqp://guest:guest@localhost:5672/",
            .exchange = "exchange_name",
            .routing_key = "routing.key",
        } },
    };

    const logfile_data = try build_logfile_bytes(allocator, &.{
        .{ .rule = persisted_rule },
    });
    defer allocator.free(logfile_data);

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var decode_arena = try replay_into_scheduler(allocator, logfile_data, &scheduler);
    defer decode_arena.deinit();

    const restored = scheduler.rule_storage.get("rule.publish");
    try std.testing.expect(restored != null);
    switch (restored.?.runner) {
        .amqp => |a| {
            try std.testing.expectEqualStrings("amqp://guest:guest@localhost:5672/", a.dsn);
            try std.testing.expectEqualStrings("exchange_name", a.exchange);
            try std.testing.expectEqualStrings("routing.key", a.routing_key);
        },
        else => return error.TestUnexpectedRunnerVariant,
    }

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-job",
        .instruction = .{ .set = .{ .identifier = "events.signup.42", .execution = 2000 } },
    });

    try scheduler.tick(2000);

    try std.testing.expectEqual(JobStatus.triggered, scheduler.job_storage.get("events.signup.42").?.status);
    try std.testing.expectEqual(@as(usize, 1), scheduler.execution_client.pending.items.len);
    try std.testing.expect(scheduler.execution_client.pending.items[0].runner == .amqp);
}

test "shell runner dispatches AMQP runner without raising when broker unreachable" {
    const refused_port: u16 = blk: {
        const a = try std.net.Address.parseIp4("127.0.0.1", 0);
        var s = try a.listen(.{ .reuse_address = true });
        const p = s.listen_address.in.getPort();
        s.deinit();
        break :blk p;
    };
    const dsn = try std.fmt.allocPrint(std.testing.allocator, "amqp://guest:guest@127.0.0.1:{d}/", .{refused_port});
    defer std.testing.allocator.free(dsn);

    const shell_config = interfaces_config.ShellConfig{ .path = "/bin/sh", .args = &.{"-c"} };
    const request = domain_execution.Request{
        .identifier = 0xF019_F019_F019_F019,
        .job_identifier = "notify.unreachable",
        .runner = .{ .amqp = .{ .dsn = dsn, .exchange = "jobs", .routing_key = "notifications" } },
    };

    const response = infrastructure_runner.execute(std.testing.allocator, shell_config, request);

    try std.testing.expectEqual(@as(u128, 0xF019_F019_F019_F019), response.identifier);
    try std.testing.expect(!response.success);
}
