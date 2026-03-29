const std = @import("std");
const domain = @import("../domain.zig");

const Job = domain.job.Job;
const JobStatus = domain.job.JobStatus;

pub const JobStorage = struct {
    allocator: std.mem.Allocator,
    jobs: std.StringHashMapUnmanaged(Job),
    to_execute: std.ArrayListUnmanaged(Job),

    pub fn init(allocator: std.mem.Allocator) JobStorage {
        return .{
            .allocator = allocator,
            .jobs = .{},
            .to_execute = .{},
        };
    }

    pub fn deinit(self: *JobStorage) void {
        self.jobs.deinit(self.allocator);
        self.to_execute.deinit(self.allocator);
    }

    pub fn get(self: *const JobStorage, identifier: []const u8) ?Job {
        return self.jobs.get(identifier);
    }

    pub fn set(self: *JobStorage, job: Job) !void {
        try self.jobs.put(self.allocator, job.identifier, job);

        var i: usize = 0;
        while (i < self.to_execute.items.len) {
            if (std.mem.eql(u8, self.to_execute.items[i].identifier, job.identifier)) {
                _ = self.to_execute.orderedRemove(i);
                break;
            }
            i += 1;
        }

        if (job.status == .planned) {
            var insert_pos: usize = self.to_execute.items.len;
            for (self.to_execute.items, 0..) |item, idx| {
                if (item.execution > job.execution) {
                    insert_pos = idx;
                    break;
                }
            }
            try self.to_execute.insert(self.allocator, insert_pos, job);
        }
    }

    pub fn get_to_execute(self: *const JobStorage, current_time: i64) []const Job {
        var count: usize = 0;
        for (self.to_execute.items) |job| {
            if (job.execution <= current_time) {
                count += 1;
            } else {
                break;
            }
        }
        return self.to_execute.items[0..count];
    }

    pub fn get_by_prefix(self: *const JobStorage, prefix: []const u8, allocator: std.mem.Allocator) ![]Job {
        var result = std.ArrayListUnmanaged(Job){};
        errdefer result.deinit(allocator);

        var it = self.jobs.valueIterator();
        while (it.next()) |job| {
            if (std.mem.startsWith(u8, job.identifier, prefix)) {
                try result.append(allocator, job.*);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn get_by_status(self: *const JobStorage, status: JobStatus, allocator: std.mem.Allocator) ![]Job {
        var result = std.ArrayListUnmanaged(Job){};
        errdefer result.deinit(allocator);

        var it = self.jobs.valueIterator();
        while (it.next()) |job| {
            if (job.status == status) {
                try result.append(allocator, job.*);
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

test "set and get" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = JobStorage.init(allocator);
    defer storage.deinit();

    const job = Job{ .identifier = "job.1", .execution = 1595586600_000000000, .status = .planned };
    try storage.set(job);

    const result = storage.get("job.1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(job, result.?);
}

test "set overwrites existing job" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = JobStorage.init(allocator);
    defer storage.deinit();

    try storage.set(Job{ .identifier = "job.1", .execution = 1595586600_000000000, .status = .planned });
    try storage.set(Job{ .identifier = "job.1", .execution = 1595586600_000000000, .status = .triggered });

    const result = storage.get("job.1");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(JobStatus.triggered, result.?.status);
}

test "get_to_execute returns planned jobs ordered by execution time" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = JobStorage.init(allocator);
    defer storage.deinit();

    const now: i64 = 1595586720_000000000;
    try storage.set(Job{ .identifier = "job.3", .execution = 1595586720_000000000, .status = .planned });
    try storage.set(Job{ .identifier = "job.1", .execution = 1595586600_000000000, .status = .planned });
    try storage.set(Job{ .identifier = "job.2", .execution = 1595586660_000000000, .status = .executed });
    try storage.set(Job{ .identifier = "job.4", .execution = 1595586780_000000000, .status = .planned });

    const result = storage.get_to_execute(now);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("job.1", result[0].identifier);
    try std.testing.expectEqualStrings("job.3", result[1].identifier);
}

test "get_by_prefix returns jobs matching prefix" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = JobStorage.init(allocator);
    defer storage.deinit();

    try storage.set(Job{ .identifier = "backup.daily", .execution = 1595586600_000000000, .status = .planned });
    try storage.set(Job{ .identifier = "backup.weekly", .execution = 1595586660_000000000, .status = .planned });
    try storage.set(Job{ .identifier = "deploy.prod", .execution = 1595586720_000000000, .status = .planned });

    const result = try storage.get_by_prefix("backup.", allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "get_by_prefix returns empty slice for no match" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = JobStorage.init(allocator);
    defer storage.deinit();

    try storage.set(Job{ .identifier = "backup.daily", .execution = 1595586600_000000000, .status = .planned });

    const result = try storage.get_by_prefix("nonexistent.", allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "get_by_prefix with empty prefix returns all jobs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = JobStorage.init(allocator);
    defer storage.deinit();

    try storage.set(Job{ .identifier = "backup.daily", .execution = 1595586600_000000000, .status = .planned });
    try storage.set(Job{ .identifier = "deploy.prod", .execution = 1595586660_000000000, .status = .planned });
    try storage.set(Job{ .identifier = "migrate.db", .execution = 1595586720_000000000, .status = .planned });

    const result = try storage.get_by_prefix("", allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "get_by_status filters by status" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var storage = JobStorage.init(allocator);
    defer storage.deinit();

    try storage.set(Job{ .identifier = "job.1", .execution = 1595586600_000000000, .status = .planned });
    try storage.set(Job{ .identifier = "job.2", .execution = 1595586660_000000000, .status = .triggered });
    try storage.set(Job{ .identifier = "job.3", .execution = 1595586720_000000000, .status = .planned });

    const planned = try storage.get_by_status(.planned, allocator);
    defer allocator.free(planned);
    try std.testing.expectEqual(@as(usize, 2), planned.len);

    const triggered = try storage.get_by_status(.triggered, allocator);
    defer allocator.free(triggered);
    try std.testing.expectEqual(@as(usize, 1), triggered.len);
    try std.testing.expectEqualStrings("job.2", triggered[0].identifier);
}
