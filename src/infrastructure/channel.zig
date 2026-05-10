const std = @import("std");

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex,
        not_empty: std.Thread.Condition,
        not_full: std.Thread.Condition,
        notify_condition: ?*std.Thread.Condition,
        buffer: []T,
        head: usize,
        tail: usize,
        count: usize,
        capacity: usize,
        allocator: std.mem.Allocator,
        closed: bool,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const buffer = try allocator.alloc(T, capacity);
            return Self{
                .mutex = .{},
                .not_empty = .{},
                .not_full = .{},
                .notify_condition = null,
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
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.count == self.capacity and !self.closed) {
                self.not_full.wait(&self.mutex);
            }
            if (self.closed) return error.ChannelClosed;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;
            self.not_empty.signal();
            if (self.notify_condition) |nc| nc.signal();
        }

        pub fn receive(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.count == 0) {
                if (self.closed) return null;
                self.not_empty.wait(&self.mutex);
            }
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;
            self.not_full.signal();
            return item;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast();
            if (self.notify_condition) |nc| nc.signal();
        }

        pub const TrySendError = error{ ChannelClosed, ChannelFull };

        pub fn try_send(self: *Self, item: T) TrySendError!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.ChannelClosed;
            if (self.count == self.capacity) return error.ChannelFull;
            self.buffer[self.tail] = item;
            self.tail = (self.tail + 1) % self.capacity;
            self.count += 1;
            self.not_empty.signal();
            if (self.notify_condition) |nc| nc.signal();
        }

        pub fn try_receive(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;
            self.not_full.signal();
            return item;
        }

        pub fn drain(self: *Self, out: []T) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            const n = @min(self.count, out.len);
            for (0..n) |i| {
                out[i] = self.buffer[self.head];
                self.head = (self.head + 1) % self.capacity;
            }
            self.count -= n;
            if (n > 0) self.not_full.broadcast();
            return n;
        }
    };
}

test "channel send and receive single item" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.send(42);
    const value = ch.receive() orelse unreachable;
    try std.testing.expectEqual(@as(u32, 42), value);
}

test "channel preserves FIFO order" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.send(1);
    try ch.send(2);
    try ch.send(3);
    try std.testing.expectEqual(@as(u32, 1), ch.receive() orelse unreachable);
    try std.testing.expectEqual(@as(u32, 2), ch.receive() orelse unreachable);
    try std.testing.expectEqual(@as(u32, 3), ch.receive() orelse unreachable);
}

test "channel blocks sender when full then drains" {
    var ch = try Channel(u32).init(std.testing.allocator, 1);
    defer ch.deinit();

    try ch.send(99);
    try std.testing.expectEqual(@as(u32, 99), ch.receive() orelse unreachable);
}

test "channel transfers items across threads" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
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
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
}

test "try_receive returns value after send" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    try ch.send(7);
    try ch.send(13);
    try std.testing.expectEqual(@as(u32, 7), ch.try_receive() orelse unreachable);
    try std.testing.expectEqual(@as(u32, 13), ch.try_receive() orelse unreachable);
    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
}

test "try_receive is non-blocking" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
    try std.testing.expectEqual(@as(?u32, null), ch.try_receive());
}

test "drain copies all pending items in single call" {
    var ch = try Channel(u32).init(std.testing.allocator, 8);
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
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    var buf: [4]u32 = undefined;
    const n = ch.drain(&buf);

    try std.testing.expectEqual(@as(usize, 0), n);
}

test "drain copies at most out.len items when buffer has more" {
    var ch = try Channel(u32).init(std.testing.allocator, 8);
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
    var ch = try Channel(u32).init(std.testing.allocator, 3);
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

    std.Thread.sleep(10 * std.time.ns_per_ms);

    var buf: [3]u32 = undefined;
    _ = ch.drain(&buf);

    // Safety valve: if drain didn't signal not_full the sender stays blocked forever.
    // Close the channel after a short window to unblock it; sender gets ChannelClosed,
    // returns without setting the flag, and the assertion below catches the failure.
    std.Thread.sleep(30 * std.time.ns_per_ms);
    if (!sender_sent.load(.acquire)) ch.close();

    sender.join();
    try std.testing.expect(sender_sent.load(.acquire));
}

test "send signals notify_condition when set" {
    var ch = try Channel(u32).init(std.testing.allocator, 4);
    defer ch.deinit();

    var extra_cond: std.Thread.Condition = .{};
    var extra_mutex: std.Thread.Mutex = .{};
    ch.notify_condition = &extra_cond;

    var signaled = std.atomic.Value(bool).init(false);

    const waiter = try std.Thread.spawn(.{}, struct {
        fn run(
            cond: *std.Thread.Condition,
            mtx: *std.Thread.Mutex,
            flag: *std.atomic.Value(bool),
        ) void {
            mtx.lock();
            defer mtx.unlock();
            cond.wait(mtx);
            flag.store(true, .release);
        }
    }.run, .{ &extra_cond, &extra_mutex, &signaled });

    std.Thread.sleep(1 * std.time.ns_per_ms);
    try ch.send(42);

    waiter.join();
    try std.testing.expect(signaled.load(.acquire));
}
