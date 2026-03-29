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

    const enc_job = try persistence_encoder.encode(allocator, .{ .job = original_job });
    defer allocator.free(enc_job);
    const enc_rule = try persistence_encoder.encode(allocator, .{ .rule = original_rule });
    defer allocator.free(enc_rule);

    const lf_job = try persistence_logfile.encode(allocator, enc_job);
    defer allocator.free(lf_job);
    const lf_rule = try persistence_logfile.encode(allocator, enc_rule);
    defer allocator.free(lf_rule);

    const combined = try allocator.alloc(u8, lf_job.len + lf_rule.len);
    defer allocator.free(combined);
    @memcpy(combined[0..lf_job.len], lf_job);
    @memcpy(combined[lf_job.len..], lf_rule);

    const parsed = try persistence_logfile.parse(allocator, combined);
    defer {
        for (parsed.entries) |e| allocator.free(e);
        allocator.free(parsed.entries);
    }

    // Arena owns all decoded string allocations, matching Scheduler.load() pattern
    var decode_arena = std.heap.ArenaAllocator.init(allocator);
    defer decode_arena.deinit();
    const arena = decode_arena.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    for (parsed.entries) |entry| {
        const decoded = try persistence_encoder.decode(arena, entry);
        switch (decoded) {
            .job => |j| try scheduler.job_storage.set(j),
            .rule => |r| try scheduler.rule_storage.set(r),
        }
    }

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
