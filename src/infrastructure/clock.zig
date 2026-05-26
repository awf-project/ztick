const std = @import("std");

pub const Clock = struct {
    framerate: u16,
    running: *std.atomic.Value(bool),
    io: std.Io,

    pub fn init(framerate: u16, running: *std.atomic.Value(bool), io: std.Io) Clock {
        return .{ .framerate = framerate, .running = running, .io = io };
    }

    fn monotonic_ns() u64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    /// Run the tick loop on the calling thread.
    ///
    /// `wake_token` is a pointer to the same `std.atomic.Value(u32)` set on
    /// the request channel's `wake_token` field.  When the channel receives a
    /// new item it atomically increments this value and calls `futexWake` on
    /// it, which unblocks the `futexWaitTimeout` below immediately rather than
    /// waiting for the full idle timeout to expire.
    ///
    /// The `_wake_mutex` parameter is kept for call-site compatibility but is
    /// not used; the futex approach does not require a mutex.
    pub fn start(
        self: Clock,
        context: anytype,
        comptime callback: fn (@TypeOf(context)) ?i64,
        _wake_mutex: *std.Io.Mutex,
        wake_token: *std.atomic.Value(u32),
    ) void {
        _ = _wake_mutex;
        const min_frame_ns: u64 = std.time.ns_per_s / @as(u64, self.framerate);
        var next_job_time: ?i64 = null;

        while (self.running.load(.acquire)) {
            const now: i64 = @intCast(monotonic_ns());
            const idle_timeout_ns: u64 = if (next_job_time) |njt| blk: {
                const diff: i64 = njt - now;
                if (diff <= 0) break :blk 0;
                break :blk @intCast(@min(diff, 1_000_000_000));
            } else 1_000_000_000;

            if (idle_timeout_ns > 0) {
                // Snapshot the token before sleeping.  If the channel sends a
                // new request after the snapshot but before futexWait, the
                // token will have changed and futexWait returns immediately.
                const token_before = wake_token.load(.acquire);
                const timeout = std.Io.Timeout{
                    .duration = .{
                        .raw = .{ .nanoseconds = @intCast(idle_timeout_ns) },
                        .clock = .awake,
                    },
                };
                // Ignore the error: Timeout.Error means the timer expired
                // normally; Canceled is not emitted by testing.io.
                std.Io.futexWaitTimeout(self.io, u32, &wake_token.raw, token_before, timeout) catch {};
                if (!self.running.load(.acquire)) break;
            }

            const tick_start = monotonic_ns();
            next_job_time = callback(context);
            const elapsed = monotonic_ns() - tick_start;
            if (elapsed < min_frame_ns) {
                const remaining = min_frame_ns - elapsed;
                const sleep_req = std.os.linux.timespec{
                    .sec = @intCast(remaining / std.time.ns_per_s),
                    .nsec = @intCast(remaining % std.time.ns_per_s),
                };
                _ = std.os.linux.nanosleep(&sleep_req, null);
            }
        }
    }
};

const TestClockArgs = struct {
    count: *std.atomic.Value(u32),
    running: *std.atomic.Value(bool),
};

fn test_clock_thread(args: TestClockArgs) void {
    var wake_mutex: std.Io.Mutex = .init;
    var wake_token = std.atomic.Value(u32).init(0);
    const clock = Clock.init(1000, args.running, std.testing.io);
    clock.start(args.count, struct {
        fn tick(cc: *std.atomic.Value(u32)) ?i64 {
            _ = cc.fetchAdd(1, .monotonic);
            return 0;
        }
    }.tick, &wake_mutex, &wake_token);
}

test "clock init sets framerate" {
    var running = std.atomic.Value(bool).init(true);
    const clock = Clock.init(60, &running, std.testing.io);
    try std.testing.expectEqual(@as(u16, 60), clock.framerate);
}

test "clock start invokes callback" {
    var running = std.atomic.Value(bool).init(true);
    var count = std.atomic.Value(u32).init(0);

    const thread = try std.Thread.spawn(.{}, test_clock_thread, .{TestClockArgs{
        .count = &count,
        .running = &running,
    }});

    var elapsed_ms: u32 = 0;
    while (count.load(.monotonic) < 1 and elapsed_ms < 2000) : (elapsed_ms += 1) {
        const req = std.os.linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&req, null);
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
    while (count.load(.monotonic) < 3 and elapsed_ms < 2000) : (elapsed_ms += 1) {
        const req = std.os.linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&req, null);
    }

    try std.testing.expect(count.load(.monotonic) >= 3);

    running.store(false, .release);
    thread.join();
}
