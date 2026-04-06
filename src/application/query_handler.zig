const std = @import("std");
const domain = @import("../domain.zig");
const JobStorage = @import("job_storage.zig").JobStorage;
const RuleStorage = @import("rule_storage.zig").RuleStorage;

const Instruction = domain.instruction.Instruction;
const Job = domain.job.Job;
const Rule = domain.rule.Rule;
const Request = domain.query.Request;
const Response = domain.query.Response;

pub const QueryHandler = struct {
    allocator: std.mem.Allocator,
    job_storage: *JobStorage,
    rule_storage: *RuleStorage,

    pub fn init(allocator: std.mem.Allocator, job_storage: *JobStorage, rule_storage: *RuleStorage) QueryHandler {
        return .{
            .allocator = allocator,
            .job_storage = job_storage,
            .rule_storage = rule_storage,
        };
    }

    pub fn handle(self: *QueryHandler, request: Request) !Response {
        const success = switch (request.instruction) {
            .set => |args| blk: {
                const job = Job{
                    .identifier = args.identifier,
                    .execution = args.execution,
                    .status = .planned,
                };
                self.job_storage.set(job) catch break :blk false;
                break :blk true;
            },
            .rule_set => |args| blk: {
                const rule = Rule{
                    .identifier = args.identifier,
                    .pattern = args.pattern,
                    .runner = args.runner,
                };
                self.rule_storage.set(rule) catch break :blk false;
                break :blk true;
            },
            .get => |args| blk: {
                const job = self.job_storage.get(args.identifier) orelse break :blk false;
                const body = try std.fmt.allocPrint(self.allocator, "{s} {d}", .{ @tagName(job.status), job.execution });
                return Response{ .request = request, .success = true, .body = body };
            },
            .query => |args| {
                const jobs = try self.job_storage.get_by_prefix(args.pattern, self.allocator);
                defer self.allocator.free(jobs);

                if (jobs.len == 0) {
                    return Response{ .request = request, .success = true };
                }

                var body_buf = std.ArrayListUnmanaged(u8){};
                errdefer body_buf.deinit(self.allocator);

                for (jobs) |job| {
                    try body_buf.writer(self.allocator).print("{s} {s} {d}\n", .{ job.identifier, @tagName(job.status), job.execution });
                }

                const body = try body_buf.toOwnedSlice(self.allocator);
                return Response{ .request = request, .success = true, .body = body };
            },
            .remove => |args| self.job_storage.delete(args.identifier),
            .remove_rule => |args| self.rule_storage.delete(args.identifier),
            .list_rules => {
                if (self.rule_storage.rules.count() == 0) {
                    return Response{ .request = request, .success = true };
                }

                var body_buf = std.ArrayListUnmanaged(u8){};
                errdefer body_buf.deinit(self.allocator);

                var it = self.rule_storage.rules.valueIterator();
                while (it.next()) |rule| {
                    switch (rule.runner) {
                        .shell => |sh| try body_buf.writer(self.allocator).print("{s} {s} shell {s}\n", .{ rule.identifier, rule.pattern, sh.command }),
                        .amqp => |mq| try body_buf.writer(self.allocator).print("{s} {s} amqp {s} {s} {s}\n", .{ rule.identifier, rule.pattern, mq.dsn, mq.exchange, mq.routing_key }),
                        .direct => |d| {
                            try body_buf.writer(self.allocator).print("{s} {s} direct {s}", .{ rule.identifier, rule.pattern, d.executable });
                            for (d.args) |arg| try body_buf.writer(self.allocator).print(" {s}", .{arg});
                            try body_buf.writer(self.allocator).writeByte('\n');
                        },
                        .awf => |awf| {
                            try body_buf.writer(self.allocator).print("{s} {s} awf {s}", .{ rule.identifier, rule.pattern, awf.workflow });
                            for (awf.inputs) |input| try body_buf.writer(self.allocator).print(" --input {s}", .{input});
                            try body_buf.writer(self.allocator).writeByte('\n');
                        },
                    }
                }

                const body = try body_buf.toOwnedSlice(self.allocator);
                return Response{ .request = request, .success = true, .body = body };
            },
            .stat => unreachable,
        };

        return Response{ .request = request, .success = success };
    }
};

test "handle set instruction stores job and returns success" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    const request = Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    };

    const response = try handler.handle(request);
    try std.testing.expect(response.success);
    try std.testing.expectEqual(request.client, response.request.client);

    const job = job_storage.get("job.1");
    try std.testing.expect(job != null);
    try std.testing.expectEqual(@as(i64, 1595586600_000000000), job.?.execution);
}

test "handle rule_set instruction stores rule and returns success" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    const request = Request{
        .client = 2,
        .identifier = "req-2",
        .instruction = .{ .rule_set = .{
            .identifier = "rule.1",
            .pattern = "job.",
            .runner = .{ .shell = .{ .command = "echo" } },
        } },
    };

    const response = try handler.handle(request);
    try std.testing.expect(response.success);

    const rule = rule_storage.get("rule.1");
    try std.testing.expect(rule != null);
    try std.testing.expectEqualStrings("job.", rule.?.pattern);
}

test "handle get instruction returns success with status and execution timestamp for existing job" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try job_storage.set(.{ .identifier = "job.1", .execution = 1595586600_000000000, .status = .planned });

    const request = Request{
        .client = 3,
        .identifier = "req-3",
        .instruction = .{ .get = .{ .identifier = "job.1" } },
    };

    const response = try handler.handle(request);
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expectEqualStrings("planned 1595586600000000000", response.body.?);
}

test "handle get instruction returns failure for missing job" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    const request = Request{
        .client = 4,
        .identifier = "req-4",
        .instruction = .{ .get = .{ .identifier = "job.missing" } },
    };

    const response = try handler.handle(request);
    try std.testing.expect(!response.success);
    try std.testing.expectEqual(@as(?[]const u8, null), response.body);
}

test "handle query instruction returns success with matching jobs in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try job_storage.set(.{ .identifier = "backup.daily", .execution = 1595586600_000000000, .status = .planned });
    try job_storage.set(.{ .identifier = "backup.weekly", .execution = 1595586660_000000000, .status = .planned });
    try job_storage.set(.{ .identifier = "deploy.prod", .execution = 1595586720_000000000, .status = .planned });

    const request = Request{
        .client = 5,
        .identifier = "req-5",
        .instruction = .{ .query = .{ .pattern = "backup." } },
    };

    const response = try handler.handle(request);
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "backup.daily") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "backup.weekly") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "deploy.prod") == null);
}

test "handle query instruction returns success with null body when no jobs match" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try job_storage.set(.{ .identifier = "deploy.prod", .execution = 1595586720_000000000, .status = .planned });

    const request = Request{
        .client = 6,
        .identifier = "req-6",
        .instruction = .{ .query = .{ .pattern = "backup." } },
    };

    const response = try handler.handle(request);
    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(?[]const u8, null), response.body);
}

test "handle query instruction with empty pattern returns all jobs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try job_storage.set(.{ .identifier = "backup.daily", .execution = 1595586600_000000000, .status = .planned });
    try job_storage.set(.{ .identifier = "deploy.prod", .execution = 1595586720_000000000, .status = .executed });

    const request = Request{
        .client = 7,
        .identifier = "req-7",
        .instruction = .{ .query = .{ .pattern = "" } },
    };

    const response = try handler.handle(request);
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "backup.daily") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "deploy.prod") != null);
}

test "handle remove instruction removes existing job and returns success" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try job_storage.set(.{ .identifier = "backup-daily", .execution = 1595586600_000000000, .status = .planned });

    const request = Request{
        .client = 8,
        .identifier = "req-8",
        .instruction = .{ .remove = .{ .identifier = "backup-daily" } },
    };

    const response = try handler.handle(request);
    try std.testing.expect(response.success);
    try std.testing.expect(job_storage.get("backup-daily") == null);
}

test "handle remove instruction returns failure for missing job" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    const request = Request{
        .client = 9,
        .identifier = "req-9",
        .instruction = .{ .remove = .{ .identifier = "nonexistent" } },
    };

    const response = try handler.handle(request);
    try std.testing.expect(!response.success);
}

test "handle remove_rule instruction removes existing rule and returns success" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try rule_storage.set(.{ .identifier = "notify-slack", .pattern = "deploy.", .runner = .{ .shell = .{ .command = "notify" } } });

    const request = Request{
        .client = 10,
        .identifier = "req-10",
        .instruction = .{ .remove_rule = .{ .identifier = "notify-slack" } },
    };

    const response = try handler.handle(request);
    try std.testing.expect(response.success);
    try std.testing.expect(rule_storage.get("notify-slack") == null);
}

test "handle remove_rule instruction returns failure for missing rule" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    const request = Request{
        .client = 11,
        .identifier = "req-11",
        .instruction = .{ .remove_rule = .{ .identifier = "ghost-rule" } },
    };

    const response = try handler.handle(request);
    try std.testing.expect(!response.success);
}

test "handle list_rules instruction returns success with null body when no rules loaded" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    const request = Request{
        .client = 12,
        .identifier = "req-12",
        .instruction = .{ .list_rules = .{} },
    };

    const response = try handler.handle(request);
    try std.testing.expect(response.success);
    try std.testing.expectEqual(@as(?[]const u8, null), response.body);
}

test "handle list_rules instruction returns success with all shell rules in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try rule_storage.set(.{ .identifier = "rule.backup", .pattern = "backup.", .runner = .{ .shell = .{ .command = "/usr/bin/backup.sh" } } });
    try rule_storage.set(.{ .identifier = "rule.notify", .pattern = "notify.", .runner = .{ .shell = .{ .command = "/usr/bin/notify.sh" } } });

    const request = Request{
        .client = 13,
        .identifier = "req-13",
        .instruction = .{ .list_rules = .{} },
    };

    const response = try handler.handle(request);
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.backup") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "backup.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "/usr/bin/backup.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.notify") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "/usr/bin/notify.sh") != null);
}

test "handle list_rules instruction returns success with amqp rule fields in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try rule_storage.set(.{ .identifier = "rule.publish", .pattern = "events.", .runner = .{ .amqp = .{
        .dsn = "amqp://localhost",
        .exchange = "exchange_name",
        .routing_key = "routing.key",
    } } });

    const request = Request{
        .client = 14,
        .identifier = "req-14",
        .instruction = .{ .list_rules = .{} },
    };

    const response = try handler.handle(request);
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

test "handle list_rules instruction returns success with direct rule without args in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try rule_storage.set(.{ .identifier = "rule.exec", .pattern = "deploy.", .runner = .{ .direct = .{
        .executable = "/usr/bin/deploy",
        .args = &.{},
    } } });

    const request = Request{
        .client = 15,
        .identifier = "req-15",
        .instruction = .{ .list_rules = .{} },
    };

    const response = try handler.handle(request);
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "deploy.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "direct") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "/usr/bin/deploy") != null);
}

test "handle list_rules instruction returns success with direct rule with args in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    const args = [_][]const u8{ "-s", "http://example.com" };
    try rule_storage.set(.{ .identifier = "rule.curl", .pattern = "fetch.", .runner = .{ .direct = .{
        .executable = "/usr/bin/curl",
        .args = &args,
    } } });

    const request = Request{
        .client = 16,
        .identifier = "req-16",
        .instruction = .{ .list_rules = .{} },
    };

    const response = try handler.handle(request);
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.curl") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "fetch.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "direct") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "/usr/bin/curl") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "-s") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "http://example.com") != null);
}

test "handle list_rules instruction returns success with awf rule without input in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try rule_storage.set(.{ .identifier = "rule.review", .pattern = "app.", .runner = .{ .awf = .{
        .workflow = "code-review",
        .inputs = &.{},
    } } });

    const request = Request{
        .client = 17,
        .identifier = "req-17",
        .instruction = .{ .list_rules = .{} },
    };

    const response = try handler.handle(request);
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.review") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "app.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "awf") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "code-review") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "--input") == null);
}

test "handle list_rules instruction returns success with awf rule with input in body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var job_storage = JobStorage.init(allocator);
    defer job_storage.deinit();
    var rule_storage = RuleStorage.init(allocator);
    defer rule_storage.deinit();

    var handler = QueryHandler.init(allocator, &job_storage, &rule_storage);

    try rule_storage.set(.{ .identifier = "rule.report", .pattern = "report.", .runner = .{ .awf = .{
        .workflow = "generate-report",
        .inputs = &.{"format=pdf"},
    } } });

    const request = Request{
        .client = 18,
        .identifier = "req-18",
        .instruction = .{ .list_rules = .{} },
    };

    const response = try handler.handle(request);
    defer if (response.body) |b| allocator.free(b);

    try std.testing.expect(response.success);
    try std.testing.expect(response.body != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "rule.report") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "report.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "awf") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "generate-report") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "--input") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body.?, "format=pdf") != null);
}
