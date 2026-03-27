const std = @import("std");

pub const Clock = struct {
    framerate: u16,
    running: *std.atomic.Value(bool),

    pub fn init(framerate: u16, running: *std.atomic.Value(bool)) Clock {
        return .{ .framerate = framerate, .running = running };
    }

    pub fn start(self: Clock, context: anytype, comptime callback: fn (@TypeOf(context)) void) void {
        const sleep_ns: u64 = std.time.ns_per_s / @as(u64, self.framerate);
        while (self.running.load(.acquire)) {
            callback(context);
            std.Thread.sleep(sleep_ns);
        }
    }
};

const TestClockArgs = struct {
    count: *std.atomic.Value(u32),
    running: *std.atomic.Value(bool),
};

fn test_clock_thread(args: TestClockArgs) void {
    const clock = Clock.init(1000, args.running);
    clock.start(args.count, struct {
        fn tick(cc: *std.atomic.Value(u32)) void {
            _ = cc.fetchAdd(1, .monotonic);
        }
    }.tick);
}

test "clock init sets framerate" {
    var running = std.atomic.Value(bool).init(true);
    const clock = Clock.init(60, &running);
    try std.testing.expectEqual(@as(u16, 60), clock.framerate);
}

test "clock start invokes callback" {
    var running = std.atomic.Value(bool).init(true);
    var count = std.atomic.Value(u32).init(0);

    const thread = try std.Thread.spawn(.{}, test_clock_thread, .{TestClockArgs{
        .count = &count,
        .running = &running,
    }});

    while (count.load(.monotonic) < 1) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(count.load(.monotonic) >= 1);

    running.store(false, .release);
    thread.join();
}

test "clock start loops calling callback multiple times" {
    var running = std.atomic.Value(bool).init(true);
    var count = std.atomic.Value(u32).init(0);

    const thread = try std.Thread.spawn(.{}, test_clock_thread, .{TestClockArgs{
        .count = &count,
        .running = &running,
    }});

    var elapsed_ms: u32 = 0;
    while (count.load(.monotonic) < 3 and elapsed_ms < 200) : (elapsed_ms += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
    }

    try std.testing.expect(count.load(.monotonic) >= 3);

    running.store(false, .release);
    thread.join();
}
