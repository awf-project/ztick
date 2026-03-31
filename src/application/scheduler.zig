const std = @import("std");
const domain = @import("../domain.zig");
const persistence = @import("../infrastructure/persistence.zig");
const JobStorage = @import("job_storage.zig").JobStorage;
const RuleStorage = @import("rule_storage.zig").RuleStorage;
const QueryHandler = @import("query_handler.zig").QueryHandler;
const ExecutionClient = @import("execution_client.zig").ExecutionClient;

const Job = domain.job.Job;
const Rule = domain.rule.Rule;
const Request = domain.query.Request;
const Response = domain.query.Response;
const Entry = persistence.encoder.Entry;
const PersistenceBackend = persistence.backend.PersistenceBackend;

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    job_storage: JobStorage,
    rule_storage: RuleStorage,
    execution_client: ExecutionClient,
    persistence: ?PersistenceBackend,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{
            .allocator = allocator,
            .job_storage = JobStorage.init(allocator),
            .rule_storage = RuleStorage.init(allocator),
            .execution_client = ExecutionClient.init(allocator),
            .persistence = null,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.job_storage.deinit();
        self.rule_storage.deinit();
        self.execution_client.deinit();
        if (self.persistence) |*b| b.deinit();
    }

    pub fn load(self: *Scheduler, allocator: std.mem.Allocator) !void {
        if (self.persistence == null) return;

        const raw_entries = try self.persistence.?.load(allocator);
        defer {
            for (raw_entries) |e| allocator.free(e);
            allocator.free(raw_entries);
        }

        self.job_storage.jobs.clearRetainingCapacity();
        self.job_storage.to_execute.clearRetainingCapacity();
        self.rule_storage.rules.clearRetainingCapacity();

        const decode_alloc = self.persistence.?.reset_decode_arena(allocator);

        for (raw_entries) |raw| {
            const entry = persistence.encoder.decode(decode_alloc, raw) catch |err| {
                std.log.warn("persistence: failed to decode entry: {}", .{err});
                continue;
            };
            try self.replay_entry(entry);
        }
    }

    pub fn replay_entry(self: *Scheduler, entry: Entry) !void {
        switch (entry) {
            .job => |job| try self.job_storage.set(job),
            .rule => |rule| try self.rule_storage.set(rule),
            .job_removal => |removal| _ = self.job_storage.delete(removal.identifier),
            .rule_removal => |removal| _ = self.rule_storage.delete(removal.identifier),
        }
    }

    pub fn handle_query(self: *Scheduler, request: Request) !Response {
        var handler = QueryHandler.init(self.allocator, &self.job_storage, &self.rule_storage);
        const response = try handler.handle(request);
        errdefer if (response.body) |b| self.allocator.free(b);

        if (response.success and self.persistence != null) {
            try self.append_to_persistence(request);
        }

        return response;
    }

    fn append_to_persistence(self: *Scheduler, request: Request) !void {
        const maybe_entry: ?Entry = switch (request.instruction) {
            .set => |s| .{ .job = .{ .identifier = s.identifier, .execution = s.execution, .status = .planned } },
            .rule_set => |r| .{ .rule = .{ .identifier = r.identifier, .pattern = r.pattern, .runner = r.runner } },
            .remove => |r| .{ .job_removal = .{ .identifier = r.identifier } },
            .remove_rule => |r| .{ .rule_removal = .{ .identifier = r.identifier } },
            .get, .query, .list_rules => null,
        };
        const entry = maybe_entry orelse return;
        const encoded = try persistence.encoder.encode(self.allocator, entry);
        defer self.allocator.free(encoded);
        try self.persistence.?.append(encoded);
    }

    pub fn tick(self: *Scheduler, current_time: i64) !void {
        const results = try self.execution_client.pull_results(self.allocator);
        defer self.allocator.free(results);

        for (results) |result| {
            if (self.job_storage.get(result.job_identifier)) |job| {
                var updated = job;
                updated.status = if (result.success) .executed else .failed;
                try self.job_storage.set(updated);
                std.log.debug("execution outcome: job={s} success={}", .{ job.identifier, result.success });
            }
        }

        const borrowed = self.job_storage.get_to_execute(current_time);
        const jobs_to_execute = try self.allocator.alloc(Job, borrowed.len);
        defer self.allocator.free(jobs_to_execute);
        @memcpy(jobs_to_execute, borrowed);

        for (jobs_to_execute) |job| {
            if (self.rule_storage.pair(job.identifier)) |rule| {
                var triggered = job;
                triggered.status = .triggered;
                try self.job_storage.set(triggered);
                try self.execution_client.trigger(job.identifier, rule.runner);
            } else {
                var failed = job;
                failed.status = .failed;
                try self.job_storage.set(failed);
            }
        }
    }
};

test "tick transitions planned job to triggered when rule matches" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1000, .status = .planned });
    try scheduler.rule_storage.set(Rule{ .identifier = "rule.1", .pattern = "job.", .runner = .{ .shell = .{ .command = "echo" } } });

    try scheduler.tick(1000);

    const job = scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(domain.job.JobStatus.triggered, job.?.status);
}

test "tick transitions planned job to failed when no rule matches" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1000, .status = .planned });

    try scheduler.tick(1000);

    const job = scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(domain.job.JobStatus.failed, job.?.status);
}

test "tick marks job as executed after successful execution result" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1000, .status = .planned });
    try scheduler.rule_storage.set(Rule{ .identifier = "rule.1", .pattern = "job.", .runner = .{ .shell = .{ .command = "echo" } } });

    try scheduler.tick(1000);

    for (scheduler.execution_client.pending.items) |req| {
        scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
    }
    scheduler.execution_client.pending.clearRetainingCapacity();

    try scheduler.tick(2000);

    const job = scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(domain.job.JobStatus.executed, job.?.status);
}

test "handle_query with set instruction stores job" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const request = Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    };

    _ = try scheduler.handle_query(request);

    const job = scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(@as(i64, 1595586600_000000000), job.?.execution);
    try std.testing.expectEqual(domain.job.JobStatus.planned, job.?.status);
}

test "load and handle_query round-trip through logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tmp_path = "/tmp/ztick-test-scheduler-roundtrip.log";

    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    {
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = PersistenceBackend{ .logfile = .{
            .logfile_path = tmp_path,
            .logfile_dir = std.fs.cwd(),
            .load_arena = null,
            .fsync_on_persist = false,
        } };
        try scheduler.load(allocator);

        _ = try scheduler.handle_query(Request{
            .client = 1,
            .identifier = "req-1",
            .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
        });

        _ = try scheduler.handle_query(Request{
            .client = 2,
            .identifier = "req-2",
            .instruction = .{ .rule_set = .{
                .identifier = "rule.1",
                .pattern = "job.",
                .runner = .{ .shell = .{ .command = "echo hello" } },
            } },
        });
    }

    {
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = PersistenceBackend{ .logfile = .{
            .logfile_path = tmp_path,
            .logfile_dir = std.fs.cwd(),
            .load_arena = null,
            .fsync_on_persist = false,
        } };
        try scheduler.load(allocator);

        const job = scheduler.job_storage.get("job.1");
        try std.testing.expect(job != null);
        try std.testing.expectEqual(@as(i64, 1595586600_000000000), job.?.execution);
        try std.testing.expectEqual(domain.job.JobStatus.planned, job.?.status);

        const rule = scheduler.rule_storage.get("rule.1");
        try std.testing.expect(rule != null);
        try std.testing.expectEqualStrings("job.", rule.?.pattern);
        try std.testing.expectEqualStrings("echo hello", rule.?.runner.shell.command);
    }
}

test "handle_query with get instruction returns success with body for existing job" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1595586600_000000000, .status = .planned });

    const request = Request{
        .client = 1,
        .identifier = "req-get-1",
        .instruction = .{ .get = .{ .identifier = "job.1" } },
    };

    const response = try scheduler.handle_query(request);
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expectEqualStrings("planned 1595586600000000000", response.body.?);
}

test "handle_query with get instruction returns failure for missing job" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    const request = Request{
        .client = 2,
        .identifier = "req-get-2",
        .instruction = .{ .get = .{ .identifier = "job.missing" } },
    };

    const response = try scheduler.handle_query(request);
    try std.testing.expect(!response.success);
    try std.testing.expectEqual(@as(?[]const u8, null), response.body);
}

test "handle_query with query instruction returns success with matching jobs in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.job_storage.set(Job{ .identifier = "backup.daily", .execution = 1595586600_000000000, .status = .planned });
    try scheduler.job_storage.set(Job{ .identifier = "backup.weekly", .execution = 1595586660_000000000, .status = .planned });
    try scheduler.job_storage.set(Job{ .identifier = "deploy.prod", .execution = 1595586720_000000000, .status = .planned });

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-query-1",
        .instruction = .{ .query = .{ .pattern = "backup." } },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "backup.daily") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "backup.weekly") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "deploy.prod") == null);
}

test "handle_query with query instruction returns success with null body when no jobs match" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.job_storage.set(Job{ .identifier = "deploy.prod", .execution = 1595586720_000000000, .status = .planned });

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-query-2",
        .instruction = .{ .query = .{ .pattern = "backup." } },
    });

    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(?[]const u8, null), response.body);
}

test "handle_query with query instruction does not persist to logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    const tmp_path = "/tmp/ztick-test-scheduler-query-no-persist.log";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = PersistenceBackend{ .logfile = .{
        .logfile_path = tmp_path,
        .logfile_dir = std.fs.cwd(),
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    });

    const size_after_set = try get_file_size(tmp_path);
    try std.testing.expect(size_after_set > 0);

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-query",
        .instruction = .{ .query = .{ .pattern = "job." } },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expectEqual(size_after_set, try get_file_size(tmp_path));
}

test "handle_query with get instruction does not persist to logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    const tmp_path = "/tmp/ztick-test-scheduler-get-no-persist.log";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = PersistenceBackend{ .logfile = .{
        .logfile_path = tmp_path,
        .logfile_dir = std.fs.cwd(),
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    });

    const size_after_set = try get_file_size(tmp_path);
    try std.testing.expect(size_after_set > 0);

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-get",
        .instruction = .{ .get = .{ .identifier = "job.1" } },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expectEqual(size_after_set, try get_file_size(tmp_path));
}

test "double load deinits previous arena without leak" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    const tmp_path = "/tmp/ztick-test-scheduler-double-load.log";

    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    {
        var writer = Scheduler.init(allocator);
        defer writer.deinit();
        writer.persistence = PersistenceBackend{ .logfile = .{
            .logfile_path = tmp_path,
            .logfile_dir = std.fs.cwd(),
            .load_arena = null,
            .fsync_on_persist = false,
        } };
        try writer.load(allocator);

        _ = try writer.handle_query(Request{
            .client = 1,
            .identifier = "req-1",
            .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1000 } },
        });
    }

    {
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = PersistenceBackend{ .logfile = .{
            .logfile_path = tmp_path,
            .logfile_dir = std.fs.cwd(),
            .load_arena = null,
            .fsync_on_persist = false,
        } };

        try scheduler.load(allocator);
        try scheduler.load(allocator);

        const job = scheduler.job_storage.get("job.1");
        try std.testing.expect(job != null);
        try std.testing.expectEqual(@as(i64, 1000), job.?.execution);
    }
}

test "handle_query with remove instruction persists to logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    const tmp_path = "/tmp/ztick-test-scheduler-remove-persist.log";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = PersistenceBackend{ .logfile = .{
        .logfile_path = tmp_path,
        .logfile_dir = std.fs.cwd(),
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    });
    const size_after_set = try get_file_size(tmp_path);

    _ = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-remove",
        .instruction = .{ .remove = .{ .identifier = "job.1" } },
    });

    try std.testing.expect(try get_file_size(tmp_path) > size_after_set);
}

test "remove job round-trip through logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    const tmp_path = "/tmp/ztick-test-scheduler-remove-roundtrip.log";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    {
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = PersistenceBackend{ .logfile = .{
            .logfile_path = tmp_path,
            .logfile_dir = std.fs.cwd(),
            .load_arena = null,
            .fsync_on_persist = false,
        } };
        try scheduler.load(allocator);

        _ = try scheduler.handle_query(Request{
            .client = 1,
            .identifier = "req-set",
            .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
        });
        _ = try scheduler.handle_query(Request{
            .client = 2,
            .identifier = "req-remove",
            .instruction = .{ .remove = .{ .identifier = "job.1" } },
        });
    }

    {
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = PersistenceBackend{ .logfile = .{
            .logfile_path = tmp_path,
            .logfile_dir = std.fs.cwd(),
            .load_arena = null,
            .fsync_on_persist = false,
        } };
        try scheduler.load(allocator);

        try std.testing.expectEqual(@as(?Job, null), scheduler.job_storage.get("job.1"));
    }
}

test "remove_rule round-trip through logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    const tmp_path = "/tmp/ztick-test-scheduler-removerule-roundtrip.log";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    {
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = PersistenceBackend{ .logfile = .{
            .logfile_path = tmp_path,
            .logfile_dir = std.fs.cwd(),
            .load_arena = null,
            .fsync_on_persist = false,
        } };
        try scheduler.load(allocator);

        _ = try scheduler.handle_query(Request{
            .client = 1,
            .identifier = "req-rule-set",
            .instruction = .{ .rule_set = .{
                .identifier = "rule.1",
                .pattern = "job.",
                .runner = .{ .shell = .{ .command = "echo hello" } },
            } },
        });
        _ = try scheduler.handle_query(Request{
            .client = 2,
            .identifier = "req-removerule",
            .instruction = .{ .remove_rule = .{ .identifier = "rule.1" } },
        });
    }

    {
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = PersistenceBackend{ .logfile = .{
            .logfile_path = tmp_path,
            .logfile_dir = std.fs.cwd(),
            .load_arena = null,
            .fsync_on_persist = false,
        } };
        try scheduler.load(allocator);

        try std.testing.expectEqual(@as(?Rule, null), scheduler.rule_storage.get("rule.1"));
    }
}

test "handle_query with list_rules instruction does not persist to logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    const tmp_path = "/tmp/ztick-test-scheduler-listrules-no-persist.log";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        file.close();
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = PersistenceBackend{ .logfile = .{
        .logfile_path = tmp_path,
        .logfile_dir = std.fs.cwd(),
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-rule-set",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.1",
            .pattern = "job.",
            .runner = .{ .shell = .{ .command = "echo hello" } },
        } },
    });

    const size_after_rule_set = try get_file_size(tmp_path);
    try std.testing.expect(size_after_rule_set > 0);

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-listrules",
        .instruction = .{ .list_rules = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expectEqual(size_after_rule_set, try get_file_size(tmp_path));
}

test "tick marks job as failed after failed execution result" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1000, .status = .planned });
    try scheduler.rule_storage.set(Rule{ .identifier = "rule.1", .pattern = "job.", .runner = .{ .shell = .{ .command = "echo" } } });

    try scheduler.tick(1000);

    for (scheduler.execution_client.pending.items) |req| {
        scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = false });
    }
    scheduler.execution_client.pending.clearRetainingCapacity();

    try scheduler.tick(2000);

    const job = scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(domain.job.JobStatus.failed, job.?.status);
}

test "tick processes execution result for unknown job without error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1000, .status = .planned });
    try scheduler.rule_storage.set(Rule{ .identifier = "rule.1", .pattern = "job.", .runner = .{ .shell = .{ .command = "echo" } } });

    try scheduler.tick(1000);

    _ = scheduler.job_storage.delete("job.1");

    for (scheduler.execution_client.pending.items) |req| {
        scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
    }
    scheduler.execution_client.pending.clearRetainingCapacity();

    try scheduler.tick(2000);
}

test "tick updates all job statuses when multiple execution results arrive in single tick" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.job_storage.set(Job{ .identifier = "job.a", .execution = 1000, .status = .planned });
    try scheduler.job_storage.set(Job{ .identifier = "job.b", .execution = 1000, .status = .planned });
    try scheduler.rule_storage.set(Rule{ .identifier = "rule.1", .pattern = "job.", .runner = .{ .shell = .{ .command = "echo" } } });

    try scheduler.tick(1000);

    for (scheduler.execution_client.pending.items) |req| {
        const success = std.mem.eql(u8, req.job_identifier, "job.a");
        scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = success });
    }
    scheduler.execution_client.pending.clearRetainingCapacity();

    try scheduler.tick(2000);

    const job_a = scheduler.job_storage.get("job.a");
    const job_b = scheduler.job_storage.get("job.b");
    try std.testing.expect(job_a != null);
    try std.testing.expect(job_b != null);
    try std.testing.expectEqual(domain.job.JobStatus.executed, job_a.?.status);
    try std.testing.expectEqual(domain.job.JobStatus.failed, job_b.?.status);
}

test "load with memory backend on empty backend loads nothing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } };
    try scheduler.load(allocator);

    try std.testing.expectEqual(@as(?Job, null), scheduler.job_storage.get("any.job"));
}

test "handle_query with set instruction round-trips through memory backend" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } };
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    });

    try scheduler.load(allocator);

    const job = scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(@as(i64, 1595586600_000000000), job.?.execution);
    try std.testing.expectEqual(domain.job.JobStatus.planned, job.?.status);
}

test "load and handle_query round-trip through memory backend" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } };
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-2",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.1",
            .pattern = "job.",
            .runner = .{ .shell = .{ .command = "echo hello" } },
        } },
    });

    try scheduler.load(allocator);

    const job = scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(@as(i64, 1595586600_000000000), job.?.execution);
    try std.testing.expectEqual(domain.job.JobStatus.planned, job.?.status);

    const rule = scheduler.rule_storage.get("rule.1");
    try std.testing.expect(rule != null);
    try std.testing.expectEqualStrings("job.", rule.?.pattern);
    try std.testing.expectEqualStrings("echo hello", rule.?.runner.shell.command);
}

test "double load with memory backend works without leak" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } };
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1000 } },
    });

    try scheduler.load(allocator);
    try scheduler.load(allocator);

    const job = scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(@as(i64, 1000), job.?.execution);
}

fn get_file_size(path: []const u8) !u64 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.size;
}
