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
        switch (decoded) {
            .job => |j| try scheduler.job_storage.set(j),
            .rule => |r| try scheduler.rule_storage.set(r),
            .job_removal => |r| _ = scheduler.job_storage.delete(r.identifier),
            .rule_removal => |r| _ = scheduler.rule_storage.delete(r.identifier),
        }
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
