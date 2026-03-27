const std = @import("std");

pub const JobStatus = enum {
    planned,
    triggered,
    executed,
    failed,
};

pub const Job = struct {
    identifier: []const u8,
    execution: i64,
    status: JobStatus,
};

test "field access" {
    const job = Job{ .identifier = "my-job", .execution = 1605457800_000000000, .status = .planned };
    try std.testing.expectEqualStrings("my-job", job.identifier);
    try std.testing.expectEqual(@as(i64, 1605457800_000000000), job.execution);
    try std.testing.expectEqual(JobStatus.planned, job.status);
}

test "JobStatus enum values" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(JobStatus.planned));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(JobStatus.triggered));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(JobStatus.executed));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(JobStatus.failed));
}

test "status byte mapping" {
    const statuses = [_]JobStatus{ .planned, .triggered, .executed, .failed };
    const expected_bytes = [_]u8{ 0, 1, 2, 3 };

    for (statuses, expected_bytes) |status, expected| {
        const byte: u8 = @intFromEnum(status);
        try std.testing.expectEqual(expected, byte);

        const roundtrip: JobStatus = @enumFromInt(byte);
        try std.testing.expectEqual(status, roundtrip);
    }
}
