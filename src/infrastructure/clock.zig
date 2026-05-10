const std = @import("std");

pub const Clock = struct {
    framerate: u16,
    running: *std.atomic.Value(bool),

    pub fn init(framerate: u16, running: *std.atomic.Value(bool)) Clock {
        return .{ .framerate = framerate, .running = running };
    }

    pub fn start(
        self: Clock,
        context: anytype,
        comptime callback: fn (@TypeOf(context)) ?i64,
        wake_mutex: *std.Thread.Mutex,
        wake_condition: *std.Thread.Condition,
    ) void {
        const min_frame_ns: u64 = std.time.ns_per_s / @as(u64, self.framerate);
        var next_job_time: ?i64 = null;

        while (self.running.load(.acquire)) {
            const now: i128 = std.time.nanoTimestamp();
            const idle_timeout_ns: u64 = if (next_job_time) |njt| blk: {
                const diff: i128 = @as(i128, njt) - now;
                if (diff <= 0) break :blk 0;
                break :blk @intCast(@min(diff, 1_000_000_000));
            } else 1_000_000_000;

            if (idle_timeout_ns > 0) {
                const wait_ns: u64 = @min(idle_timeout_ns, min_frame_ns);
                wake_mutex.lock();
                wake_condition.timedWait(wake_mutex, wait_ns) catch {};
                wake_mutex.unlock();
                if (!self.running.load(.acquire)) break;
            }

            const tick_start: i128 = std.time.nanoTimestamp();
            next_job_time = callback(context);
            const elapsed: i128 = std.time.nanoTimestamp() - tick_start;
            if (elapsed >= 0 and @as(u64, @intCast(elapsed)) < min_frame_ns) {
                std.Thread.sleep(min_frame_ns - @as(u64, @intCast(elapsed)));
            }
        }
    }
};

const TestClockArgs = struct {
    count: *std.atomic.Value(u32),
    running: *std.atomic.Value(bool),
};

fn test_clock_thread(args: TestClockArgs) void {
    var wake_mutex = std.Thread.Mutex{};
    var wake_condition = std.Thread.Condition{};
    const clock = Clock.init(1000, args.running);
    clock.start(args.count, struct {
        fn tick(cc: *std.atomic.Value(u32)) ?i64 {
            _ = cc.fetchAdd(1, .monotonic);
            return null;
        }
    }.tick, &wake_mutex, &wake_condition);
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

const WakeTestArgs = struct {
    count: *std.atomic.Value(u32),
    running: *std.atomic.Value(bool),
    wake_mutex: *std.Thread.Mutex,
    wake_condition: *std.Thread.Condition,
};

fn slow_clock_thread(args: WakeTestArgs) void {
    const clock = Clock.init(1, args.running);
    clock.start(args.count, struct {
        fn tick(cc: *std.atomic.Value(u32)) ?i64 {
            _ = cc.fetchAdd(1, .monotonic);
            return null;
        }
    }.tick, args.wake_mutex, args.wake_condition);
}

fn capped_clock_thread(args: WakeTestArgs) void {
    const clock = Clock.init(100, args.running);
    clock.start(args.count, struct {
        fn tick(cc: *std.atomic.Value(u32)) ?i64 {
            _ = cc.fetchAdd(1, .monotonic);
            return null;
        }
    }.tick, args.wake_mutex, args.wake_condition);
}

test "clock wakes immediately when condition is signaled" {
    var running = std.atomic.Value(bool).init(true);
    var count = std.atomic.Value(u32).init(0);
    var wake_mutex = std.Thread.Mutex{};
    var wake_condition = std.Thread.Condition{};

    const thread = try std.Thread.spawn(.{}, slow_clock_thread, .{WakeTestArgs{
        .count = &count,
        .running = &running,
        .wake_mutex = &wake_mutex,
        .wake_condition = &wake_condition,
    }});
    defer {
        running.store(false, .release);
        wake_mutex.lock();
        wake_condition.signal();
        wake_mutex.unlock();
        thread.join();
    }

    std.Thread.sleep(10 * std.time.ns_per_ms);
    const count_before = count.load(.monotonic);

    wake_mutex.lock();
    wake_condition.signal();
    wake_mutex.unlock();

    std.Thread.sleep(10 * std.time.ns_per_ms);
    const count_after = count.load(.monotonic);

    try std.testing.expect(count_after > count_before);
}

test "clock respects framerate cap under continuous signals" {
    var running = std.atomic.Value(bool).init(true);
    var count = std.atomic.Value(u32).init(0);
    var wake_mutex = std.Thread.Mutex{};
    var wake_condition = std.Thread.Condition{};

    const thread = try std.Thread.spawn(.{}, capped_clock_thread, .{WakeTestArgs{
        .count = &count,
        .running = &running,
        .wake_mutex = &wake_mutex,
        .wake_condition = &wake_condition,
    }});
    defer {
        running.store(false, .release);
        wake_mutex.lock();
        wake_condition.signal();
        wake_mutex.unlock();
        thread.join();
    }

    const start_time = std.time.nanoTimestamp();
    while (std.time.nanoTimestamp() - start_time < 100 * std.time.ns_per_ms) {
        wake_mutex.lock();
        wake_condition.signal();
        wake_mutex.unlock();
        std.Thread.sleep(std.time.ns_per_ms);
    }

    const tick_count = count.load(.monotonic);
    try std.testing.expect(tick_count <= 100 / 10 + 2);
}
