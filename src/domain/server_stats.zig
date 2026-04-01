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

    pub fn format(self: ServerStats, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);
        try w.print("uptime_ns {}\n", .{self.uptime_ns});
        try w.print("connections {}\n", .{self.connections});
        try w.print("jobs_total {}\n", .{self.jobs_total});
        try w.print("jobs_planned {}\n", .{self.jobs_planned});
        try w.print("jobs_triggered {}\n", .{self.jobs_triggered});
        try w.print("jobs_executed {}\n", .{self.jobs_executed});
        try w.print("jobs_failed {}\n", .{self.jobs_failed});
        try w.print("rules_total {}\n", .{self.rules_total});
        try w.print("executions_pending {}\n", .{self.executions_pending});
        try w.print("executions_inflight {}\n", .{self.executions_inflight});
        try w.print("persistence {s}\n", .{self.persistence});
        try w.print("compression {s}\n", .{self.compression});
        try w.print("auth_enabled {}\n", .{@intFromBool(self.auth_enabled)});
        try w.print("tls_enabled {}\n", .{@intFromBool(self.tls_enabled)});
        try w.print("framerate {}\n", .{self.framerate});
        return buf.toOwnedSlice(allocator);
    }
};

test "format returns all 15 required metric lines" {
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

    const result = try stats.format(allocator);
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

test "format encodes booleans as 1 and 0" {
    const allocator = std.testing.allocator;
    const stats_auth_tls = ServerStats{
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

    const result = try stats_auth_tls.format(allocator);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "auth_enabled 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "tls_enabled 1\n") != null);
}

test "format produces metrics in consistent order" {
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

    const result = try stats.format(allocator);
    defer allocator.free(result);

    const uptime_pos = std.mem.indexOf(u8, result, "uptime_ns") orelse return error.TestUnexpectedResult;
    const connections_pos = std.mem.indexOf(u8, result, "connections") orelse return error.TestUnexpectedResult;
    const jobs_total_pos = std.mem.indexOf(u8, result, "jobs_total") orelse return error.TestUnexpectedResult;
    const framerate_pos = std.mem.indexOf(u8, result, "framerate") orelse return error.TestUnexpectedResult;

    try std.testing.expect(uptime_pos < connections_pos);
    try std.testing.expect(connections_pos < jobs_total_pos);
    try std.testing.expect(jobs_total_pos < framerate_pos);
}
