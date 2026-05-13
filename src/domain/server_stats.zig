const std = @import("std");

pub const ServerStats = struct {
    uptime_ns: i128,
    connections: usize,
    jobs_total: usize,
    jobs_planned: usize,
    jobs_triggered: usize,
    jobs_executed: usize,
    jobs_failed: usize,
    rules_total: usize,
    executions_pending: usize,
    executions_inflight: usize,
    persistence: []const u8,
    compression: []const u8,
    auth_enabled: bool,
    tls_enabled: bool,
    framerate: u16,
};

test "server stats stores all fields" {
    const stats = ServerStats{
        .uptime_ns = 5_000_000_000,
        .connections = 3,
        .jobs_total = 10,
        .jobs_planned = 4,
        .jobs_triggered = 2,
        .jobs_executed = 3,
        .jobs_failed = 1,
        .rules_total = 5,
        .executions_pending = 2,
        .executions_inflight = 1,
        .persistence = "logfile",
        .compression = "idle",
        .auth_enabled = true,
        .tls_enabled = false,
        .framerate = 100,
    };
    try std.testing.expectEqual(@as(i128, 5_000_000_000), stats.uptime_ns);
    try std.testing.expectEqual(@as(usize, 3), stats.connections);
    try std.testing.expectEqual(@as(usize, 10), stats.jobs_total);
    try std.testing.expectEqual(@as(usize, 4), stats.jobs_planned);
    try std.testing.expectEqual(@as(usize, 2), stats.jobs_triggered);
    try std.testing.expectEqual(@as(usize, 3), stats.jobs_executed);
    try std.testing.expectEqual(@as(usize, 1), stats.jobs_failed);
    try std.testing.expectEqual(@as(usize, 5), stats.rules_total);
    try std.testing.expectEqual(@as(usize, 2), stats.executions_pending);
    try std.testing.expectEqual(@as(usize, 1), stats.executions_inflight);
    try std.testing.expectEqualStrings("logfile", stats.persistence);
    try std.testing.expectEqualStrings("idle", stats.compression);
    try std.testing.expect(stats.auth_enabled);
    try std.testing.expect(!stats.tls_enabled);
    try std.testing.expectEqual(@as(u16, 100), stats.framerate);
}
