const std = @import("std");
const instruction = @import("instruction.zig");

pub const Client = u128;

pub const Request = struct {
    client: Client,
    identifier: []const u8,
    instruction: instruction.Instruction,
};

pub const Response = struct {
    request: Request,
    success: bool,
    body: ?[]const u8 = null,
};

test "query request stores client identifier and instruction" {
    const req = Request{
        .client = 42,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 1595586600_000000000 } },
    };
    try std.testing.expectEqual(@as(Client, 42), req.client);
    try std.testing.expectEqualStrings("req-1", req.identifier);
    try std.testing.expectEqualStrings("job.1", req.instruction.set.identifier);
}

test "query response links request and reports success" {
    const req = Request{
        .client = 1,
        .identifier = "req-1",
        .instruction = .{ .set = .{ .identifier = "job.1", .execution = 0 } },
    };
    const resp = Response{ .request = req, .success = true };
    try std.testing.expect(resp.success);
    try std.testing.expectEqual(@as(Client, 1), resp.request.client);
}

test "query response body defaults to null" {
    const req = Request{
        .client = 2,
        .identifier = "req-2",
        .instruction = .{ .set = .{ .identifier = "job.2", .execution = 0 } },
    };
    const resp = Response{ .request = req, .success = true };
    try std.testing.expectEqual(@as(?[]const u8, null), resp.body);
}

test "query response body carries job data for get responses" {
    const req = Request{
        .client = 3,
        .identifier = "req-3",
        .instruction = .{ .get = .{ .identifier = "job.3" } },
    };
    const resp = Response{ .request = req, .success = true, .body = "planned 1595586600000000000" };
    try std.testing.expect(resp.success);
    try std.testing.expectEqualStrings("planned 1595586600000000000", resp.body.?);
}
