const std = @import("std");
const domain = @import("../domain.zig");
const codec = @import("persistence_codec.zig");
const app_instruments = @import("instruments.zig");
const JobStorage = @import("job_storage.zig").JobStorage;
const RuleStorage = @import("rule_storage.zig").RuleStorage;
const QueryHandler = @import("query_handler.zig").QueryHandler;
const ExecutionClient = @import("execution_client.zig").ExecutionClient;

const Job = domain.job.Job;
const Rule = domain.rule.Rule;
const Request = domain.query.Request;
const Response = domain.query.Response;
const Entry = codec.Entry;
const ServerStats = domain.server_stats.ServerStats;

pub fn SchedulerWith(comptime Backend: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        job_storage: JobStorage,
        rule_storage: RuleStorage,
        execution_client: ExecutionClient,
        persistence: ?Backend,
        compression_interval_ns: u64,
        last_compression_ns: u64,
        instruments: ?app_instruments.Instruments,
        startup_ns: i128,
        active_connections: ?*std.atomic.Value(usize),
        auth_enabled: bool,
        tls_enabled: bool,
        framerate: u16,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .job_storage = JobStorage.init(allocator),
                .rule_storage = RuleStorage.init(allocator),
                .execution_client = ExecutionClient.init(allocator),
                .persistence = null,
                .compression_interval_ns = 0,
                .last_compression_ns = 0,
                .instruments = null,
                .startup_ns = 0,
                .active_connections = null,
                .auth_enabled = false,
                .tls_enabled = false,
                .framerate = 0,
            };
        }

        pub fn set_instruments(self: *Self, instr: app_instruments.Instruments) void {
            self.instruments = instr;
        }

        pub fn set_stat_context(self: *Self, startup_ns: i128, active_connections: *std.atomic.Value(usize), auth_enabled: bool, tls_enabled: bool, framerate: u16) void {
            self.startup_ns = startup_ns;
            self.active_connections = active_connections;
            self.auth_enabled = auth_enabled;
            self.tls_enabled = tls_enabled;
            self.framerate = framerate;
        }

        pub fn deinit(self: *Self) void {
            self.job_storage.deinit();
            self.rule_storage.deinit();
            self.execution_client.deinit();
            if (self.persistence) |*p| p.deinit();
        }

        pub fn load(self: *Self, allocator: std.mem.Allocator) !void {
            if (self.persistence == null) return;

            const raw_entries = try self.persistence.?.load(allocator);
            defer {
                for (raw_entries) |e| allocator.free(e);
                allocator.free(raw_entries);
            }

            self.job_storage.jobs.clearRetainingCapacity();
            while (self.job_storage.to_execute.removeOrNull()) |_| {}
            self.rule_storage.rules.clearRetainingCapacity();

            const decode_alloc = self.persistence.?.reset_decode_arena(allocator);

            for (raw_entries) |raw| {
                const entry = codec.decode(decode_alloc, raw) catch |err| {
                    std.log.warn("persistence: failed to decode entry: {}", .{err});
                    continue;
                };
                try self.replay_entry(entry);
            }
        }

        pub fn replay_entry(self: *Self, entry: Entry) !void {
            switch (entry) {
                .job => |job| try self.job_storage.set(job),
                .rule => |rule| try self.rule_storage.set(rule),
                .job_removal => |removal| _ = self.job_storage.delete(removal.identifier),
                .rule_removal => |removal| _ = self.rule_storage.delete(removal.identifier),
            }
        }

        fn handle_stat_request(self: *Self, request: Request) !Response {
            const uptime_ns = std.time.nanoTimestamp() - self.startup_ns;
            const connections: usize = if (self.active_connections) |ac| ac.load(.acquire) else 0;

            const jobs_total = self.job_storage.count();
            const status_counts = self.job_storage.count_by_status();

            const rules_total = self.rule_storage.count();
            const executions_pending = self.execution_client.pending.items.len;
            const executions_inflight = self.execution_client.triggered.count();

            const persistence_str: []const u8 = if (self.persistence) |*p| p.name() else "memory";

            const compression_str: []const u8 = if (self.persistence) |*p|
                switch (p.compression_status()) {
                    .idle => "idle",
                    .running => "running",
                    .success => "success",
                    .failure => "failure",
                }
            else
                "idle";

            const stats = ServerStats{
                .uptime_ns = uptime_ns,
                .connections = connections,
                .jobs_total = jobs_total,
                .jobs_planned = status_counts.planned,
                .jobs_triggered = status_counts.triggered,
                .jobs_executed = status_counts.executed,
                .jobs_failed = status_counts.failed,
                .rules_total = rules_total,
                .executions_pending = executions_pending,
                .executions_inflight = executions_inflight,
                .persistence = persistence_str,
                .compression = compression_str,
                .auth_enabled = self.auth_enabled,
                .tls_enabled = self.tls_enabled,
                .framerate = self.framerate,
            };

            const body = try format_server_stats(self.allocator, stats);
            return Response{ .request = request, .success = true, .body = body };
        }

        pub fn handle_query(self: *Self, request: Request) !Response {
            switch (request.instruction) {
                .stat => return try self.handle_stat_request(request),
                else => {},
            }

            const command = @tagName(request.instruction);
            var span: ?app_instruments.Span = if (self.instruments) |instr|
                (instr.tracer.startSpan(self.allocator, "ztick.request", .{ .kind = .Server }) catch null)
            else
                null;
            if (span != null) {
                span.?.setAttribute("ztick.request.id", .{ .string = request.identifier }) catch {};
                span.?.setAttribute("ztick.command", .{ .string = command }) catch {};
            }
            defer if (span) |*s| {
                // Set end_time_unix_nano before endSpan because the SDK exports the span
                // in onSpanEnd (via SimpleProcessor) before its defer calls span.end().
                s.end_time_unix_nano = @intCast(std.time.nanoTimestamp());
                if (self.instruments) |instr| instr.tracer.endSpan(s);
                s.deinit();
            };

            var handler = QueryHandler.init(self.allocator, &self.job_storage, &self.rule_storage);
            const response = try handler.handle(request);
            errdefer if (response.body) |b| self.allocator.free(b);
            errdefer if (response.error_message) |m| self.allocator.free(m);

            if (span != null) {
                span.?.setAttribute("ztick.success", .{ .bool = response.success }) catch {};
            }

            if (response.success and self.persistence != null) {
                try self.append_to_persistence(request);
            }

            if (response.success) {
                if (self.instruments) |instr| {
                    switch (request.instruction) {
                        .set => try instr.jobs_scheduled.add(1, .{}),
                        .remove => try instr.jobs_removed.add(1, .{}),
                        .rule_set => try instr.rules_active.add(1, .{}),
                        .remove_rule => try instr.rules_active.add(-1, .{}),
                        .get, .query, .list_rules, .stat => {},
                    }
                }
            }

            return response;
        }

        fn append_to_persistence(self: *Self, request: Request) !void {
            const maybe_entry: ?Entry = switch (request.instruction) {
                .set => |s| .{ .job = .{ .identifier = s.identifier, .execution = s.execution, .status = .planned } },
                .rule_set => |r| .{ .rule = .{ .identifier = r.identifier, .pattern = r.pattern, .runner = r.runner } },
                .remove => |r| .{ .job_removal = .{ .identifier = r.identifier } },
                .remove_rule => |r| .{ .rule_removal = .{ .identifier = r.identifier } },
                .get, .query, .list_rules, .stat => null,
            };
            const entry = maybe_entry orelse return;
            const encoded = try codec.encode(self.allocator, entry);
            defer self.allocator.free(encoded);
            try self.persistence.?.append(encoded);
        }

        pub fn tick(self: *Self, current_time: i64) !void {
            const results = try self.execution_client.pull_results(self.allocator);
            defer {
                for (results) |result| self.allocator.free(result.job_identifier);
                self.allocator.free(results);
            }

            for (results) |result| {
                if (self.job_storage.get(result.job_identifier)) |job| {
                    var updated = job;
                    updated.status = if (result.success) .executed else .failed;
                    try self.job_storage.set(updated);
                    std.log.debug("execution outcome: job={s} success={}", .{ job.identifier, result.success });
                    if (self.instruments) |instr| {
                        try instr.jobs_executed.add(1, .{});
                        if (result.success) {
                            const duration_ms = @as(f64, @floatFromInt(current_time - job.execution)) / 1_000_000.0;
                            try instr.execution_duration_ms.record(@max(0.0, duration_ms), .{});
                        }
                    }
                }
            }

            const jobs_to_execute = try self.job_storage.get_to_execute(current_time, self.allocator);
            defer self.allocator.free(jobs_to_execute);

            for (jobs_to_execute) |job| {
                if (self.rule_storage.pair(job.identifier)) |rule| {
                    var triggered = job;
                    triggered.status = .triggered;
                    try self.job_storage.set(triggered);
                    try self.execution_client.trigger(job.identifier, rule.runner, job.execution);
                } else {
                    var failed = job;
                    failed.status = .failed;
                    try self.job_storage.set(failed);
                }
            }

            try self.maybe_trigger_compression(current_time);
        }

        fn maybe_trigger_compression(self: *Self, current_time: i64) !void {
            if (self.persistence == null) return;

            // First finish any previously completed compression process.
            self.persistence.?.finish_compression();

            // Then attempt to start a new one if the interval has elapsed.
            const current_time_u64: u64 = if (current_time > 0) @intCast(current_time) else return;
            if (current_time_u64 < self.last_compression_ns) return;
            if (self.compression_interval_ns > 0 and
                current_time_u64 - self.last_compression_ns >= self.compression_interval_ns)
            {
                if (try self.persistence.?.start_compression(self.allocator, current_time_u64)) {
                    self.last_compression_ns = current_time_u64;
                }
            }
        }
    };
}

pub fn format_server_stats(allocator: std.mem.Allocator, stats: ServerStats) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.print("uptime_ns {}\n", .{stats.uptime_ns});
    try w.print("connections {}\n", .{stats.connections});
    try w.print("jobs_total {}\n", .{stats.jobs_total});
    try w.print("jobs_planned {}\n", .{stats.jobs_planned});
    try w.print("jobs_triggered {}\n", .{stats.jobs_triggered});
    try w.print("jobs_executed {}\n", .{stats.jobs_executed});
    try w.print("jobs_failed {}\n", .{stats.jobs_failed});
    try w.print("rules_total {}\n", .{stats.rules_total});
    try w.print("executions_pending {}\n", .{stats.executions_pending});
    try w.print("executions_inflight {}\n", .{stats.executions_inflight});
    try w.print("persistence {s}\n", .{stats.persistence});
    try w.print("compression {s}\n", .{stats.compression});
    try w.print("auth_enabled {}\n", .{@intFromBool(stats.auth_enabled)});
    try w.print("tls_enabled {}\n", .{@intFromBool(stats.tls_enabled)});
    try w.print("framerate {}\n", .{stats.framerate});
    return buf.toOwnedSlice(allocator);
}

// ─── Test helpers ──────────────────────────────────────────────────────────────

/// Import infrastructure types locally within test blocks to construct test fixtures.
/// These imports are intentionally scoped to tests and do not appear in production code.
const testing_backend = @import("../infrastructure/persistence/backend.zig");
const testing_background = @import("../infrastructure/persistence/background.zig");
const testing_telemetry = @import("../infrastructure/telemetry.zig");

const PersistenceBackend = testing_backend.PersistenceBackend;
const BackendState = testing_backend.BackendState;
const Process = testing_background.Process;

const Scheduler = SchedulerWith(BackendState);

// ─── Tests ────────────────────────────────────────────────────────────────────

test "format_server_stats returns all 15 required metric lines" {
    const allocator = std.testing.allocator;
    const stats = ServerStats{
        .uptime_ns = 60_000_000_000,
        .connections = 3,
        .jobs_total = 42,
        .jobs_planned = 30,
        .jobs_triggered = 2,
        .jobs_executed = 8,
        .jobs_failed = 2,
        .rules_total = 5,
        .executions_pending = 1,
        .executions_inflight = 1,
        .persistence = "logfile",
        .compression = "idle",
        .auth_enabled = true,
        .tls_enabled = false,
        .framerate = 512,
    };

    const result = try format_server_stats(allocator, stats);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "uptime_ns 60000000000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "connections 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "jobs_total 42\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "jobs_planned 30\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "jobs_triggered 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "jobs_executed 8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "jobs_failed 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "rules_total 5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "executions_pending 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "executions_inflight 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "persistence logfile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "compression idle\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "auth_enabled 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "tls_enabled 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "framerate 512\n") != null);
}

test "format_server_stats encodes booleans as 1 and 0" {
    const allocator = std.testing.allocator;
    const stats = ServerStats{
        .uptime_ns = 1,
        .connections = 0,
        .jobs_total = 0,
        .jobs_planned = 0,
        .jobs_triggered = 0,
        .jobs_executed = 0,
        .jobs_failed = 0,
        .rules_total = 0,
        .executions_pending = 0,
        .executions_inflight = 0,
        .persistence = "memory",
        .compression = "idle",
        .auth_enabled = true,
        .tls_enabled = true,
        .framerate = 1,
    };

    const result = try format_server_stats(allocator, stats);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "auth_enabled 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "tls_enabled 1\n") != null);
}

test "format_server_stats produces metrics in consistent order" {
    const allocator = std.testing.allocator;
    const stats = ServerStats{
        .uptime_ns = 100,
        .connections = 1,
        .jobs_total = 0,
        .jobs_planned = 0,
        .jobs_triggered = 0,
        .jobs_executed = 0,
        .jobs_failed = 0,
        .rules_total = 0,
        .executions_pending = 0,
        .executions_inflight = 0,
        .persistence = "logfile",
        .compression = "running",
        .auth_enabled = false,
        .tls_enabled = false,
        .framerate = 100,
    };

    const result = try format_server_stats(allocator, stats);
    defer allocator.free(result);

    const uptime_pos = std.mem.indexOf(u8, result, "uptime_ns") orelse return error.TestUnexpectedResult;
    const connections_pos = std.mem.indexOf(u8, result, "connections") orelse return error.TestUnexpectedResult;
    const jobs_total_pos = std.mem.indexOf(u8, result, "jobs_total") orelse return error.TestUnexpectedResult;
    const framerate_pos = std.mem.indexOf(u8, result, "framerate") orelse return error.TestUnexpectedResult;

    try std.testing.expect(uptime_pos < connections_pos);
    try std.testing.expect(connections_pos < jobs_total_pos);
    try std.testing.expect(jobs_total_pos < framerate_pos);
}

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
        try scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    {
        const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
            .logfile_path = "logfile",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
        } });
        var scheduler = Scheduler.init(allocator);
        scheduler.persistence = backend_state;
        defer scheduler.deinit();
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
        const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
            .logfile_path = "logfile",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
        } });
        var scheduler = Scheduler.init(allocator);
        scheduler.persistence = backend_state;
        defer scheduler.deinit();
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
    defer _ = gpa.deinit();
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
    defer if (response.error_message) |m| allocator.free(m);
    try std.testing.expect(!response.success);
    try std.testing.expectEqual(@as(?[]const u8, null), response.body);
}

test "handle_query with query instruction returns success with matching jobs in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
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
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    });

    const size_after_set = try get_file_size_in(tmp.dir, "logfile");
    try std.testing.expect(size_after_set > 0);

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-query",
        .instruction = .{ .query = .{ .pattern = "job." } },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expectEqual(size_after_set, try get_file_size_in(tmp.dir, "logfile"));
}

test "handle_query with get instruction does not persist to logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    });

    const size_after_set = try get_file_size_in(tmp.dir, "logfile");
    try std.testing.expect(size_after_set > 0);

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-get",
        .instruction = .{ .get = .{ .identifier = "job.1" } },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expectEqual(size_after_set, try get_file_size_in(tmp.dir, "logfile"));
}

test "double load deinits previous arena without leak" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    {
        const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
            .logfile_path = "logfile",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
        } });
        var writer = Scheduler.init(allocator);
        defer writer.deinit();
        writer.persistence = backend_state;
        try writer.load(allocator);

        _ = try writer.handle_query(Request{
            .client = 1,
            .identifier = "req-1",
            .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1000 } },
        });
    }

    {
        const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
            .logfile_path = "logfile",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
        } });
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = backend_state;

        try scheduler.load(allocator);
        try scheduler.load(allocator);

        const job = scheduler.job_storage.get("job.1");
        try std.testing.expect(job != null);
        try std.testing.expectEqual(@as(i64, 1000), job.?.execution);
    }
}

test "handle_query with remove instruction persists to logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    });
    const size_after_set = try get_file_size_in(tmp.dir, "logfile");

    _ = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-remove",
        .instruction = .{ .remove = .{ .identifier = "job.1" } },
    });

    try std.testing.expect(try get_file_size_in(tmp.dir, "logfile") > size_after_set);
}

test "remove job round-trip through logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    {
        const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
            .logfile_path = "logfile",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
        } });
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = backend_state;
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
        const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
            .logfile_path = "logfile",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
        } });
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = backend_state;
        try scheduler.load(allocator);

        try std.testing.expectEqual(@as(?Job, null), scheduler.job_storage.get("job.1"));
    }
}

test "remove_rule round-trip through logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    {
        const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
            .logfile_path = "logfile",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
        } });
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = backend_state;
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
        const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
            .logfile_path = "logfile",
            .logfile_dir = tmp.dir,
            .load_arena = null,
            .fsync_on_persist = false,
        } });
        var scheduler = Scheduler.init(allocator);
        defer scheduler.deinit();
        scheduler.persistence = backend_state;
        try scheduler.load(allocator);

        try std.testing.expectEqual(@as(?Rule, null), scheduler.rule_storage.get("rule.1"));
    }
}

test "handle_query with list_rules instruction does not persist to logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
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

    const size_after_rule_set = try get_file_size_in(tmp.dir, "logfile");
    try std.testing.expect(size_after_rule_set > 0);

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-listrules",
        .instruction = .{ .list_rules = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expectEqual(size_after_rule_set, try get_file_size_in(tmp.dir, "logfile"));
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
        try scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = false });
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
        try scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
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
        try scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = success });
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

    const backend_state = BackendState.init(PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    try scheduler.load(allocator);

    try std.testing.expectEqual(@as(?Job, null), scheduler.job_storage.get("any.job"));
}

test "handle_query with set instruction round-trips through memory backend" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend_state = BackendState.init(PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
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
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend_state = BackendState.init(PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
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
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend_state = BackendState.init(PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
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

fn get_file_size_in(dir: std.fs.Dir, path: []const u8) !u64 {
    const file = try dir.openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.size;
}

test "fresh scheduler disables compression by default" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(u64, 0), scheduler.compression_interval_ns);
}

test "fresh scheduler has no prior compression timestamp" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(u64, 0), scheduler.last_compression_ns);
}

test "fresh scheduler has no active compression process" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend_state = BackendState.init(PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;

    // Fresh backend state has no active process.
    try std.testing.expectEqual(@as(?*Process, null), scheduler.persistence.?.active_process);
}

test "tick triggers compression after interval elapses for logfile backend" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    scheduler.compression_interval_ns = 1000;

    try scheduler.tick(1000);

    defer {
        if (scheduler.persistence.?.active_process) |proc| {
            proc.deinit();
            scheduler.persistence.?.active_process = null;
        }
    }

    try std.testing.expect(scheduler.persistence.?.active_process != null);
    try std.testing.expectEqual(@as(u64, 1000), scheduler.last_compression_ns);
}

test "tick renames logfile to .to_compress before spawning compression" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    scheduler.compression_interval_ns = 1000;

    try scheduler.tick(1000);

    defer {
        if (scheduler.persistence.?.active_process) |proc| {
            proc.deinit();
            scheduler.persistence.?.active_process = null;
        }
    }

    _ = try tmp.dir.statFile("logfile.to_compress");
}

test "tick skips compression when backend is memory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend_state = BackendState.init(PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    scheduler.compression_interval_ns = 1000;

    try scheduler.tick(1000);

    try std.testing.expectEqual(@as(?*Process, null), scheduler.persistence.?.active_process);
}

test "tick skips compression when interval is zero" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    scheduler.compression_interval_ns = 0;

    try scheduler.tick(1000);

    try std.testing.expectEqual(@as(?*Process, null), scheduler.persistence.?.active_process);
}

test "tick cleans up completed compression process" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend_state = BackendState.init(PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    scheduler.compression_interval_ns = 1000;

    const TaskResult = testing_background.TaskResult;
    const proc = try Process.execute(allocator, struct {
        fn run() TaskResult {
            return {};
        }
    }.run);
    if (proc.thread) |t| t.join();
    proc.joined = true;
    scheduler.persistence.?.active_process = proc;

    try scheduler.tick(999);

    const was_cleaned_up = scheduler.persistence.?.active_process == null;

    // Free whatever the stub left behind to prevent GPA leak
    if (scheduler.persistence.?.active_process) |p| {
        p.deinit();
        scheduler.persistence.?.active_process = null;
    }

    try std.testing.expect(was_cleaned_up);
}

test "tick skips compression when process is already running" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    scheduler.compression_interval_ns = 1000;

    const running_proc = try allocator.create(Process);
    running_proc.* = .{ .allocator = allocator, .thread = undefined, .result = null, .mutex = .{}, .joined = true };
    scheduler.persistence.?.active_process = running_proc;

    try scheduler.tick(1000);

    const still_same = scheduler.persistence.?.active_process == running_proc;

    // Manual cleanup: thread is undefined (no real thread was spawned)
    if (scheduler.persistence.?.active_process) |p| {
        p.deinit();
        scheduler.persistence.?.active_process = null;
    }

    try std.testing.expect(still_same);
}

test "deinit frees active compression process allocation without joining thread" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const backend_state = BackendState.init(PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = allocator } });
    var scheduler = Scheduler.init(allocator);
    scheduler.persistence = backend_state;

    const proc = try allocator.create(Process);
    proc.* = .{ .allocator = allocator, .thread = undefined, .result = null, .mutex = .{}, .joined = true };
    scheduler.persistence.?.active_process = proc;

    scheduler.deinit();
    // backend_state.deinit() is called through the scheduler's deinit,
    // which frees active_process. No double-free.
}

test "tick logs warning and retains .to_compress when compression fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile.to_compress", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    scheduler.compression_interval_ns = 1_000_000_000;

    const TaskResult = testing_background.TaskResult;
    const proc = try allocator.create(Process);
    proc.* = .{ .allocator = allocator, .thread = undefined, .result = @as(TaskResult, error.Failure), .mutex = .{}, .joined = true };
    scheduler.persistence.?.active_process = proc;

    try scheduler.tick(500_000_000);

    try std.testing.expectEqual(@as(?*Process, null), scheduler.persistence.?.active_process);
    _ = try tmp.dir.statFile("logfile.to_compress");
}

const TestOtelContext = struct {
    scheduler: Scheduler,
    meter_provider: *@import("opentelemetry").metrics.MeterProvider,
    tracer_provider: *@import("opentelemetry").trace.TracerProvider,

    fn init(allocator: std.mem.Allocator) !TestOtelContext {
        const otel = @import("opentelemetry");
        const meter_provider = try otel.metrics.MeterProvider.init(allocator);
        errdefer meter_provider.shutdown();
        const tracer_provider = try otel.trace.TracerProvider.init(
            allocator,
            otel.trace.IDGenerator{ .Random = otel.trace.RandomIDGenerator.init(std.crypto.random) },
        );
        errdefer tracer_provider.shutdown();

        var scheduler = Scheduler.init(allocator);
        scheduler.set_instruments(try testing_telemetry.createInstruments(meter_provider, tracer_provider));

        return .{
            .scheduler = scheduler,
            .meter_provider = meter_provider,
            .tracer_provider = tracer_provider,
        };
    }

    fn deinit(self: *TestOtelContext) void {
        self.scheduler.deinit();
        self.tracer_provider.shutdown();
        self.meter_provider.shutdown();
    }
};

test "handle_query SET with instruments calls jobs_scheduled counter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try TestOtelContext.init(allocator);
    defer ctx.deinit();

    const response = try ctx.scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1000 } },
    });
    try std.testing.expect(response.success);

    const job = ctx.scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
}

test "handle_query REMOVE with instruments calls jobs_removed counter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try TestOtelContext.init(allocator);
    defer ctx.deinit();

    try ctx.scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1000, .status = .planned });

    const response = try ctx.scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .remove = .{ .identifier = "job.1" } },
    });
    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(?Job, null), ctx.scheduler.job_storage.get("job.1"));
}

test "handle_query RULE_SET with instruments updates rules_active gauge" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try TestOtelContext.init(allocator);
    defer ctx.deinit();

    const response = try ctx.scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.1",
            .pattern = "job.",
            .runner = .{ .shell = .{ .command = "echo" } },
        } },
    });
    try std.testing.expect(response.success);

    const rule = ctx.scheduler.rule_storage.get("rule.1");
    try std.testing.expect(rule != null);
}

test "tick increments jobs_executed counter on successful execution result" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try TestOtelContext.init(allocator);
    defer ctx.deinit();

    try ctx.scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1000, .status = .planned });
    try ctx.scheduler.rule_storage.set(Rule{ .identifier = "rule.1", .pattern = "job.", .runner = .{ .shell = .{ .command = "echo" } } });

    try ctx.scheduler.tick(1000);

    for (ctx.scheduler.execution_client.pending.items) |req| {
        try ctx.scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
    }
    ctx.scheduler.execution_client.pending.clearRetainingCapacity();

    try ctx.scheduler.tick(2000);

    const job = ctx.scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(domain.job.JobStatus.executed, job.?.status);
}

test "tick records execution duration in histogram for executed job" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try TestOtelContext.init(allocator);
    defer ctx.deinit();

    try ctx.scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1000, .status = .planned });
    try ctx.scheduler.rule_storage.set(Rule{ .identifier = "rule.1", .pattern = "job.", .runner = .{ .shell = .{ .command = "echo" } } });

    try ctx.scheduler.tick(1000);

    for (ctx.scheduler.execution_client.pending.items) |req| {
        try ctx.scheduler.execution_client.resolve(.{ .identifier = req.identifier, .success = true });
    }
    ctx.scheduler.execution_client.pending.clearRetainingCapacity();

    try ctx.scheduler.tick(2000);

    const job = ctx.scheduler.job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(domain.job.JobStatus.executed, job.?.status);
}

test "scheduler with null instruments completes operations without error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(?app_instruments.Instruments, null), scheduler.instruments);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1000 } },
    });

    _ = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-2",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.1",
            .pattern = "job.",
            .runner = .{ .shell = .{ .command = "echo" } },
        } },
    });

    try scheduler.tick(1000);
    try scheduler.tick(2000);
}

test "handle_query with stat instruction returns success with all metric keys in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var connections = std.atomic.Value(usize).init(1);
    scheduler.set_stat_context(1_000_000_000, &connections, false, false, 100);

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-stat",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    const body = response.body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "uptime_ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "connections") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_planned") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_triggered") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_executed") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "rules_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "executions_pending") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "executions_inflight") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "persistence") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "compression") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "auth_enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tls_enabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "framerate") != null);
}

test "handle_query with stat instruction reflects pre-populated job counts" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var connections = std.atomic.Value(usize).init(0);
    scheduler.set_stat_context(0, &connections, false, false, 1);

    try scheduler.job_storage.set(Job{ .identifier = "job.1", .execution = 1000, .status = .planned });
    try scheduler.job_storage.set(Job{ .identifier = "job.2", .execution = 2000, .status = .planned });
    try scheduler.job_storage.set(Job{ .identifier = "job.3", .execution = 3000, .status = .executed });
    try scheduler.job_storage.set(Job{ .identifier = "job.4", .execution = 4000, .status = .failed });

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-stat-counts",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    const body = response.body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_total 4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_planned 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_executed 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "jobs_failed 1\n") != null);
}

test "handle_query with stat instruction with active instruments does not update any counter" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try TestOtelContext.init(allocator);
    defer ctx.deinit();

    var connections = std.atomic.Value(usize).init(0);
    ctx.scheduler.set_stat_context(0, &connections, false, false, 1);

    const response = try ctx.scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-stat-instruments",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
}

test "handle_query with stat instruction does not persist to logfile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    try scheduler.load(allocator);

    _ = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-set",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    });

    const size_after_set = try get_file_size_in(tmp.dir, "logfile");
    try std.testing.expect(size_after_set > 0);

    var connections = std.atomic.Value(usize).init(1);
    scheduler.set_stat_context(0, &connections, false, false, 1);

    const response = try scheduler.handle_query(Request{
        .client = 2,
        .identifier = "req-stat-nopersist",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expectEqual(size_after_set, try get_file_size_in(tmp.dir, "logfile"));
}

test "handle_query with stat instruction reports active_connections value from atomic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var connections = std.atomic.Value(usize).init(7);
    scheduler.set_stat_context(0, &connections, false, false, 1);

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-stat-conn",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "connections 7\n") != null);
}

test "handle_query with stat instruction reports auth_enabled and tls_enabled as 1 when configured" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var connections = std.atomic.Value(usize).init(1);
    scheduler.set_stat_context(0, &connections, true, true, 1);

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-stat-auth",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "auth_enabled 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "tls_enabled 1\n") != null);
}

test "handle_query with stat instruction reports framerate and rules_total values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();

    var connections = std.atomic.Value(usize).init(0);
    scheduler.set_stat_context(0, &connections, false, false, 512);

    try scheduler.rule_storage.set(Rule{ .identifier = "rule.1", .pattern = "backup.", .runner = .{ .shell = .{ .command = "echo" } } });
    try scheduler.rule_storage.set(Rule{ .identifier = "rule.2", .pattern = "deploy.", .runner = .{ .shell = .{ .command = "echo" } } });

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-stat-cfg",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "framerate 512\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rules_total 2\n") != null);
}

test "handle_query with stat instruction reports persistence backend type" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("logfile", .{});
        f.close();
    }

    const backend_state = BackendState.init(PersistenceBackend{ .logfile = .{
        .logfile_path = "logfile",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } });
    var scheduler = Scheduler.init(allocator);
    defer scheduler.deinit();
    scheduler.persistence = backend_state;
    try scheduler.load(allocator);

    var connections = std.atomic.Value(usize).init(0);
    scheduler.set_stat_context(0, &connections, false, false, 1);

    const response = try scheduler.handle_query(Request{
        .client = 1,
        .identifier = "req-stat-persist",
        .instruction = .{ .stat = .{} },
    });
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "persistence logfile\n") != null);
}
