const std = @import("std");
const domain_job = @import("domain/job.zig");
const domain_rule = @import("domain/rule.zig");
const domain_query = @import("domain/query.zig");
const application_scheduler = @import("application/scheduler.zig");
const persistence_encoder = @import("infrastructure/persistence/encoder.zig");
const persistence_logfile = @import("infrastructure/persistence/logfile.zig");
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

    std.Thread.sleep(500_000_000);

    openssl.stdin.?.close();
    openssl.stdin = null;

    std.Thread.sleep(200_000_000);

    // Read openssl stdout for the server response
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
    while (stdout_filled < stdout_buf.len) {
        const n = stdout_file.read(stdout_buf[stdout_filled..]) catch break;
        if (n == 0) break;
        stdout_filled += n;
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

    // Verify the server processed the SET instruction
    try std.testing.expect(std.mem.indexOf(u8, stderr_output, "[DEBUG] instruction received: set") != null);

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
    const n: usize = bad_conn.read(&read_buf) catch |err| switch (err) {
        error.ConnectionResetByPeer, error.WouldBlock => 0,
        else => {
            bad_conn.close();
            server.tmp_dir.dir.deleteFile("test_tls_bad_handshake.db") catch {};
            return err;
        },
    };
    bad_conn.close();

    try std.testing.expectEqual(@as(usize, 0), n);

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
