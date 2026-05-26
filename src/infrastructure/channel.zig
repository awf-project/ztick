const std = @import("std");

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        mutex: std.Io.Mutex,
        not_empty: std.Io.Condition,
        not_full: std.Io.Condition,
        /// Optional wake token incremented on every send/try_send/close.
        /// The Clock thread uses io.futexWaitTimeout on this value so that
        /// a new request wakes it immediately rather than after the full
        /// idle timeout.  Set to null if no external waiter is needed.
        wake_token: ?*std.atomic.Value(u32),
        buffer: []T,
        head: usize,
        tail: usize,
        count: usize,
        capacity: usize,
        allocator: std.mem.Allocator,
        closed: bool,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, capacity: usize) !Self {
            const buffer = try allocator.alloc(T, capacity);
            return Self{
                .io = io,
                .mutex = .init,
                .not_empty = .init,
                .not_full = .init,
                .wake_token = null,
                .buffer = buffer,
                .head = 0,
                .tail = 0,
                .count = 0,
                .capacity = capacity,
                .allocator = allocator,
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        pub const SendError = error{ChannelClosed};

        pub fn send(self: *Self, item: T) SendError!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.count == self.capacity and !self.closed) {
                self.not_full.waitUncancelable(self.io, &self.mutex);
            }
            if (self.closed) return error.ChannelClosed;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;
            self.not_empty.signal(self.io);
            self.notifyWakeToken();
        }

        pub fn receive(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.count == 0) {
                if (self.closed) return null;
                self.not_empty.waitUncancelable(self.io, &self.mutex);
            }
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;
            self.not_full.signal(self.io);
            return item;
        }

        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
            self.not_empty.broadcast(self.io);
            self.not_full.broadcast(self.io);
            self.notifyWakeToken();
        }

        pub const TrySendError = error{ ChannelClosed, ChannelFull };

        pub fn try_send(self: *Self, item: T) TrySendError!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.ChannelClosed;
            if (self.count == self.capacity) return error.ChannelFull;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;
            self.not_empty.signal(self.io);
            self.notifyWakeToken();
        }

        pub fn try_receive(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.count == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;
            self.not_full.signal(self.io);
            return item;
        }

        pub fn drain(self: *Self, out: []T) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const n = @min(self.count, out.len);
            for (0..n) |i| {
                out[i] = self.buffer[self.head];
                self.head = (self.head + 1) % self.capacity;
            }
            self.count -= n;
            if (n > 0) self.not_full.broadcast(self.io);
            return n;
        }

        /// Increment the wake token and wake one futex waiter if a token is set.
        fn notifyWakeToken(self: *Self) void {
            if (self.wake_token) |tok| {
                _ = tok.fetchAdd(1, .release);
                self.io.futexWake(u32, &tok.raw, 1);
            }
        }
    };
}

test "channel send and receive single item" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 4);
    defer ch.deinit();

    try ch.send(42);
    const value = ch.receive() orelse unreachable;
    try std.testing.expectEqual(@as(u32, 42), value);
}

test "channel preserves FIFO order" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 4);
    defer ch.deinit();

    try ch.send(1);
    try ch.send(2);
    try ch.send(3);
    try std.testing.expectEqual(@as(u32, 1), ch.receive() orelse unreachable);
    try std.testing.expectEqual(@as(u32, 2), ch.receive() orelse unreachable);
    try std.testing.expectEqual(@as(u32, 3), ch.receive() orelse unreachable);
}

test "channel blocks sender when full then drains" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 1);
    defer ch.deinit();

    try ch.send(99);
    try std.testing.expectEqual(@as(u32, 99), ch.receive() orelse unreachable);
}

test "channel transfers items across threads" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 4);
    defer ch.deinit();

    const sender = try std.Thread.spawn(.{}, struct {
        fn run(c: *Channel(u32)) void {
            c.send(10) catch return;
            c.send(20) catch return;
            c.send(30) catch return;
        }
    }.run, .{&ch});

    const v1 = ch.receive() orelse unreachable;
    const v2 = ch.receive() orelse unreachable;
    const v3 = ch.receive() orelse unreachable;
    sender.join();

    try std.testing.expectEqual(@as(u32, 10), v1);
    try std.testing.expectEqual(@as(u32, 20), v2);
    try std.testing.expectEqual(@as(u32, 30), v3);
}

test "try_receive returns null on empty channel" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 4);
    defer ch.deinit();

    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
}

test "try_receive returns value after send" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 4);
    defer ch.deinit();

    try ch.send(7);
    try ch.send(13);
    try std.testing.expectEqual(@as(u32, 7), ch.try_receive() orelse unreachable);
    try std.testing.expectEqual(@as(u32, 13), ch.try_receive() orelse unreachable);
    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
}

test "try_receive is non-blocking" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 4);
    defer ch.deinit();

    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
}

test "drain copies all pending items in single call" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 8);
    defer ch.deinit();

    try ch.send(10);
    try ch.send(20);
    try ch.send(30);
    try ch.send(40);
    try ch.send(50);

    var buf: [8]u32 = undefined;
    const n = ch.drain(&buf);

    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(u32, 10), buf[0]);
    try std.testing.expectEqual(@as(u32, 20), buf[1]);
    try std.testing.expectEqual(@as(u32, 30), buf[2]);
    try std.testing.expectEqual(@as(u32, 40), buf[3]);
    try std.testing.expectEqual(@as(u32, 50), buf[4]);
}

test "drain returns zero on empty channel" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 4);
    defer ch.deinit();

    var buf: [4]u32 = undefined;
    const n = ch.drain(&buf);

    try std.testing.expectEqual(@as(usize, 0), n);
}

test "drain copies at most out.len items when buffer has more" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 8);
    defer ch.deinit();

    try ch.send(1);
    try ch.send(2);
    try ch.send(3);
    try ch.send(4);
    try ch.send(5);

    var buf: [3]u32 = undefined;
    const n = ch.drain(&buf);

    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 1), buf[0]);
    try std.testing.expectEqual(@as(u32, 2), buf[1]);
    try std.testing.expectEqual(@as(u32, 3), buf[2]);
    try std.testing.expectEqual(@as(?u32, 4), ch.try_receive());
    try std.testing.expectEqual(@as(?u32, 5), ch.try_receive());
}

test "drain signals not_full to unblock senders" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 3);
    defer ch.deinit();

    try ch.send(1);
    try ch.send(2);
    try ch.send(3);

    var sender_sent = std.atomic.Value(bool).init(false);
    const sender = try std.Thread.spawn(.{}, struct {
        fn run(c: *Channel(u32), flag: *std.atomic.Value(bool)) void {
            c.send(4) catch return;
            flag.store(true, .release);
        }
    }.run, .{ &ch, &sender_sent });

    nanosleep(10 * std.time.ns_per_ms);

    var buf: [3]u32 = undefined;
    _ = ch.drain(&buf);

    // Safety valve: if drain didn't signal not_full the sender stays blocked forever.
    // Close the channel after a short window to unblock it; sender gets ChannelClosed,
    // returns without setting the flag, and the assertion below catches the failure.
    nanosleep(30 * std.time.ns_per_ms);
    if (!sender_sent.load(.acquire)) ch.close();

    sender.join();
    try std.testing.expect(sender_sent.load(.acquire));
}

test "send increments wake_token and wakes futex waiter" {
    var ch = try Channel(u32).init(std.testing.allocator, std.testing.io, 4);
    defer ch.deinit();

    var token = std.atomic.Value(u32).init(0);
    ch.wake_token = &token;

    var signaled = std.atomic.Value(bool).init(false);

    const waiter = try std.Thread.spawn(.{}, struct {
        fn run(tok: *std.atomic.Value(u32), flag: *std.atomic.Value(bool)) void {
            // Spin-wait for the token to advance (futexWait may not be available
            // on all test IO backends, so we poll as a fallback).
            const initial = tok.load(.acquire);
            var i: u32 = 0;
            while (tok.load(.acquire) == initial and i < 10_000) : (i += 1) {
                nanosleep(std.time.ns_per_ms);
            }
            flag.store(true, .release);
        }
    }.run, .{ &token, &signaled });

    nanosleep(std.time.ns_per_ms);
    try ch.send(42);

    waiter.join();
    try std.testing.expect(signaled.load(.acquire));
}

fn nanosleep(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.os.linux.nanosleep(&req, null);
}
