const std = @import("std");
const domain = @import("../domain.zig");
const interfaces = @import("../interfaces.zig");

const amqp = @import("runner/amqp.zig");
const awf = @import("runner/awf.zig");
const direct = @import("runner/direct.zig");
const http = @import("runner/http.zig");
const redis = @import("runner/redis.zig");
const shell = @import("runner/shell.zig");

const execution = domain.execution;
const ShellConfig = interfaces.config.ShellConfig;

pub fn execute(allocator: std.mem.Allocator, shell_config: ShellConfig, request: execution.Request) execution.Response {
    return switch (request.runner) {
        .shell => |s| shell.execute(allocator, shell_config, s, request),
        .direct => |d| direct.execute(allocator, d, request),
        .amqp => |a| amqp.execute(allocator, a, request),
        .http => |h| http.execute(allocator, h, request),
        .awf => |a| awf.execute(allocator, a, request),
        .redis => |r| redis.execute(allocator, r, request),
    };
}

test {
    std.testing.refAllDecls(@This());
}
