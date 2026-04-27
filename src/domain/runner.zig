pub const Runner = union(enum) {
    shell: struct {
        command: []const u8,
    },
    amqp: struct {
        dsn: []const u8,
        exchange: []const u8,
        routing_key: []const u8,
    },
    redis: struct {
        url: []const u8,
        command: []const u8,
        key: []const u8,
    },
    direct: struct {
        executable: []const u8,
        args: []const []const u8,
    },
    awf: struct {
        workflow: []const u8,
        inputs: []const []const u8,
    },
    http: struct {
        method: []const u8,
        url: []const u8,
    },
};

const std = @import("std");

test "direct runner stores executable path" {
    const runner = Runner{ .direct = .{ .executable = "/bin/echo", .args = &.{} } };
    try std.testing.expectEqualStrings("/bin/echo", runner.direct.executable);
    try std.testing.expectEqual(@as(usize, 0), runner.direct.args.len);
}

test "direct runner stores args as separate elements" {
    const args = [_][]const u8{ "-s", "http://example.com" };
    const runner = Runner{ .direct = .{ .executable = "/usr/bin/curl", .args = &args } };
    try std.testing.expectEqualStrings("/usr/bin/curl", runner.direct.executable);
    try std.testing.expectEqual(@as(usize, 2), runner.direct.args.len);
    try std.testing.expectEqualStrings("-s", runner.direct.args[0]);
    try std.testing.expectEqualStrings("http://example.com", runner.direct.args[1]);
}

test "awf runner stores workflow without inputs" {
    const runner = Runner{ .awf = .{ .workflow = "code-review", .inputs = &.{} } };
    try std.testing.expectEqualStrings("code-review", runner.awf.workflow);
    try std.testing.expectEqual(@as(usize, 0), runner.awf.inputs.len);
}

test "awf runner stores workflow with inputs" {
    const inputs = [_][]const u8{ "format=pdf", "target=main" };
    const runner = Runner{ .awf = .{ .workflow = "generate-report", .inputs = &inputs } };
    try std.testing.expectEqualStrings("generate-report", runner.awf.workflow);
    try std.testing.expectEqual(@as(usize, 2), runner.awf.inputs.len);
    try std.testing.expectEqualStrings("format=pdf", runner.awf.inputs[0]);
    try std.testing.expectEqualStrings("target=main", runner.awf.inputs[1]);
}

test "direct runner is matched by exhaustive switch" {
    const args = [_][]const u8{"hello world"};
    const runner = Runner{ .direct = .{ .executable = "/bin/echo", .args = &args } };
    const tag: []const u8 = switch (runner) {
        .shell => "shell",
        .amqp => "amqp",
        .redis => "redis",
        .direct => "direct",
        .awf => "awf",
        .http => "http",
    };
    try std.testing.expectEqualStrings("direct", tag);
}

test "http runner stores method and url" {
    const runner = Runner{ .http = .{ .method = "POST", .url = "https://hooks.example.com/webhook" } };
    try std.testing.expectEqualStrings("POST", runner.http.method);
    try std.testing.expectEqualStrings("https://hooks.example.com/webhook", runner.http.url);
}

test "http runner stores GET method with http url" {
    const runner = Runner{ .http = .{ .method = "GET", .url = "http://api.internal/trigger" } };
    try std.testing.expectEqualStrings("GET", runner.http.method);
    try std.testing.expectEqualStrings("http://api.internal/trigger", runner.http.url);
}

test "http runner is matched by exhaustive switch" {
    const runner = Runner{ .http = .{ .method = "DELETE", .url = "https://api.example.com/resource/1" } };
    const tag: []const u8 = switch (runner) {
        .shell => "shell",
        .amqp => "amqp",
        .redis => "redis",
        .direct => "direct",
        .awf => "awf",
        .http => "http",
    };
    try std.testing.expectEqualStrings("http", tag);
}

test "redis runner stores url command and key" {
    const runner = Runner{ .redis = .{ .url = "redis://localhost:6379/0", .command = "PUBLISH", .key = "deploy:events" } };
    try std.testing.expectEqualStrings("redis://localhost:6379/0", runner.redis.url);
    try std.testing.expectEqualStrings("PUBLISH", runner.redis.command);
    try std.testing.expectEqualStrings("deploy:events", runner.redis.key);
}

test "redis runner is matched by exhaustive switch" {
    const runner = Runner{ .redis = .{ .url = "redis://localhost:6379/0", .command = "RPUSH", .key = "backup:tasks" } };
    const tag: []const u8 = switch (runner) {
        .shell => "shell",
        .amqp => "amqp",
        .redis => "redis",
        .direct => "direct",
        .awf => "awf",
        .http => "http",
    };
    try std.testing.expectEqualStrings("redis", tag);
}
