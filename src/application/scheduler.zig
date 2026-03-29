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

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    job_storage: JobStorage,
    rule_storage: RuleStorage,
    execution_client: ExecutionClient,
    logfile_path: ?[]const u8,
    /// Borrowed: caller keeps this Dir open; Scheduler does not close it.
    logfile_dir: ?std.fs.Dir,
    load_arena: ?std.heap.ArenaAllocator,
    fsync_on_persist: bool,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{
            .allocator = allocator,
            .job_storage = JobStorage.init(allocator),
            .rule_storage = RuleStorage.init(allocator),
            .execution_client = ExecutionClient.init(allocator),
            .logfile_path = null,
            .logfile_dir = null,
            .load_arena = null,
            .fsync_on_persist = true,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.job_storage.deinit();
        self.rule_storage.deinit();
        self.execution_client.deinit();
        if (self.load_arena) |*arena| arena.deinit();
    }

    pub fn load(self: *Scheduler, allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !void {
        self.logfile_path = path;
        self.logfile_dir = dir;

        const file = dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(data);

        const result = try persistence.logfile.parse(allocator, data);
        defer {
            for (result.entries) |e| allocator.free(e);
            allocator.free(result.entries);
        }

        if (self.load_arena) |*existing| {
            self.job_storage.deinit();
            self.job_storage = JobStorage.init(self.allocator);
            self.rule_storage.deinit();
            self.rule_storage = RuleStorage.init(self.allocator);
            existing.deinit();
        }
        self.load_arena = std.heap.ArenaAllocator.init(allocator);
        const arena = self.load_arena.?.allocator();

        for (result.entries) |entry_data| {
            const entry = persistence.encoder.decode(arena, entry_data) catch continue;
            switch (entry) {
                .job => |job| try self.job_storage.set(job),
                .rule => |rule| try self.rule_storage.set(rule),
            }
        }
    }

    pub fn handle_query(self: *Scheduler, request: Request) !Response {
        var handler = QueryHandler.init(self.allocator, &self.job_storage, &self.rule_storage);
        const response = try handler.handle(request);
        errdefer if (response.body) |b| self.allocator.free(b);

        if (response.success and self.logfile_path != null) {
            try self.append_to_logfile(request);
        }

        return response;
    }

    fn append_to_logfile(self: *Scheduler, request: Request) !void {
        const dir = self.logfile_dir.?;
        const path = self.logfile_path.?;
        const entry: Entry = switch (request.instruction) {
            .set => |args| .{ .job = .{
                .identifier = args.identifier,
                .execution = args.execution,
                .status = .planned,
            } },
            .rule_set => |args| .{ .rule = .{
                .identifier = args.identifier,
                .pattern = args.pattern,
                .runner = args.runner,
            } },
            .get, .query => return,
        };

        const encoded = try persistence.encoder.encode(self.allocator, entry);
        defer self.allocator.free(encoded);

        const framed = try persistence.logfile.encode(self.allocator, encoded);
        defer self.allocator.free(framed);

        // Direct append is crash-safe: length-prefixed framing makes partial writes
        // detectable by the parser. Atomic rename is used for full file replacement
        // (see background.compress), not incremental appends.
        const file = dir.openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(path, .{}),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(framed);
        if (self.fsync_on_persist) try file.sync();
    }

    pub fn tick(self: *Scheduler, current_time: i64) !void {
        const results = try self.execution_client.pull_results(self.allocator);
        defer self.allocator.free(results);

        for (results) |result| {
            if (self.job_storage.get(result.job_identifier)) |job| {
                var updated = job;
                updated.status = if (result.success) .executed else .failed;
                try self.job_storage.set(updated);
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
        try scheduler.load(allocator, std.fs.cwd(), tmp_path);

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
        try scheduler.load(allocator, std.fs.cwd(), tmp_path);

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
    try scheduler.load(allocator, std.fs.cwd(), tmp_path);

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
    try scheduler.load(allocator, std.fs.cwd(), tmp_path);

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
        try writer.load(allocator, std.fs.cwd(), tmp_path);

        _ = try writer.handle_query(Request{
            .client = 1,
            .identifier = "req-1",
            .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1000 } },
        });
    }

    {
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();

        try scheduler.load(allocator, std.fs.cwd(), tmp_path);
        try scheduler.load(allocator, std.fs.cwd(), tmp_path);

        const job = scheduler.job_storage.get("job.1");
        try std.testing.expect(job != null);
        try std.testing.expectEqual(@as(i64, 1000), job.?.execution);
    }
}

fn get_file_size(path: []const u8) !u64 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.size;
}
