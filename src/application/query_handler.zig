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
