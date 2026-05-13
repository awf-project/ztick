const std = @import("std");
const logfile = @import("logfile.zig");
const encoder = @import("encoder.zig");
const background = @import("background.zig");
const domain = @import("../../domain.zig");

pub const CompressionStatus = enum { idle, running, success, failure };

pub const LogfilePersistence = struct {
    logfile_path: ?[]const u8,
    logfile_dir: ?std.fs.Dir,
    load_arena: ?std.heap.ArenaAllocator,
    fsync_on_persist: bool,

    pub fn append(self: *LogfilePersistence, entry: []const u8) !void {
        const path = self.logfile_path orelse return;
        const dir = self.logfile_dir orelse return;

        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(entry.len), .big);

        const file = dir.openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(path, .{}),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(&header);
        try file.writeAll(entry);
        if (self.fsync_on_persist) try file.sync();
    }

    pub fn load(self: *LogfilePersistence, allocator: std.mem.Allocator) ![][]u8 {
        const path = self.logfile_path orelse return try allocator.alloc([]u8, 0);
        const dir = self.logfile_dir orelse return try allocator.alloc([]u8, 0);

        const file = dir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return try allocator.alloc([]u8, 0),
            else => return err,
        };
        defer file.close();

        var entries = std.ArrayListUnmanaged([]u8){};
        errdefer {
            for (entries.items) |e| allocator.free(e);
            entries.deinit(allocator);
        }

        var carry = std.ArrayListUnmanaged(u8){};
        defer carry.deinit(allocator);

        var read_buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try file.read(&read_buf);
            if (n == 0) break;
            try carry.appendSlice(allocator, read_buf[0..n]);

            const parsed = try logfile.parse(allocator, carry.items);
            for (parsed.entries) |e| {
                try entries.append(allocator, e);
            }
            allocator.free(parsed.entries);

            const rem = parsed.remaining;
            if (rem.len > 0) {
                std.mem.copyForwards(u8, carry.items[0..rem.len], rem);
            }
            carry.shrinkRetainingCapacity(rem.len);
        }

        return try entries.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *LogfilePersistence) void {
        if (self.load_arena) |*a| a.deinit();
    }
};

pub const MemoryPersistence = struct {
    entries: std.ArrayListUnmanaged([]u8),
    allocator: std.mem.Allocator,
    load_arena: ?std.heap.ArenaAllocator = null,

    pub fn append(self: *MemoryPersistence, entry: []const u8) !void {
        const owned = try self.allocator.dupe(u8, entry);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, owned);
    }

    pub fn load(self: *MemoryPersistence, allocator: std.mem.Allocator) ![][]u8 {
        const result = try allocator.alloc([]u8, self.entries.items.len);
        errdefer allocator.free(result);
        var i: usize = 0;
        errdefer for (result[0..i]) |e| allocator.free(e);
        while (i < self.entries.items.len) : (i += 1) {
            result[i] = try allocator.dupe(u8, self.entries.items[i]);
        }
        return result;
    }

    pub fn deinit(self: *MemoryPersistence) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
        if (self.load_arena) |*a| a.deinit();
    }
};

pub const PersistenceBackend = union(enum) {
    logfile: LogfilePersistence,
    memory: MemoryPersistence,

    pub fn append(self: *PersistenceBackend, entry: []const u8) !void {
        switch (self.*) {
            .logfile => |*b| try b.append(entry),
            .memory => |*b| try b.append(entry),
        }
    }

    pub fn load(self: *PersistenceBackend, allocator: std.mem.Allocator) ![][]u8 {
        return switch (self.*) {
            .logfile => |*b| b.load(allocator),
            .memory => |*b| b.load(allocator),
        };
    }

    pub fn deinit(self: *PersistenceBackend) void {
        switch (self.*) {
            .logfile => |*b| b.deinit(),
            .memory => |*b| b.deinit(),
        }
    }

    pub fn reset_decode_arena(self: *PersistenceBackend, allocator: std.mem.Allocator) std.mem.Allocator {
        switch (self.*) {
            .logfile => |*b| {
                if (b.load_arena) |*old| old.deinit();
                b.load_arena = std.heap.ArenaAllocator.init(allocator);
                return b.load_arena.?.allocator();
            },
            .memory => |*b| {
                if (b.load_arena) |*old| old.deinit();
                b.load_arena = std.heap.ArenaAllocator.init(b.allocator);
                return b.load_arena.?.allocator();
            },
        }
    }
};

/// BackendState wraps a PersistenceBackend with the compression tracking fields.
/// The scheduler stores this by value and calls its methods directly — zero vtable
/// overhead, the compiler can inline all persistence calls.
pub const BackendState = struct {
    backend: PersistenceBackend,
    active_process: ?*background.Process,

    pub fn init(backend: PersistenceBackend) BackendState {
        return .{
            .backend = backend,
            .active_process = null,
        };
    }

    pub fn deinit(self: *BackendState) void {
        if (self.active_process) |proc| {
            if (!proc.joined) if (proc.thread) |t| t.join();
            proc.deinit();
            self.active_process = null;
        }
        self.backend.deinit();
    }

    pub fn append(self: *BackendState, entry: []const u8) !void {
        return self.backend.append(entry);
    }

    pub fn load(self: *BackendState, allocator: std.mem.Allocator) ![][]u8 {
        return self.backend.load(allocator);
    }

    pub fn reset_decode_arena(self: *BackendState, allocator: std.mem.Allocator) std.mem.Allocator {
        return self.backend.reset_decode_arena(allocator);
    }

    pub fn name(self: *BackendState) []const u8 {
        return switch (self.backend) {
            .logfile => "logfile",
            .memory => "memory",
        };
    }

    pub fn compression_status(self: *BackendState) CompressionStatus {
        const proc = self.active_process orelse return .idle;
        return switch (proc.status()) {
            .running => .running,
            .success => .success,
            .failure => .failure,
        };
    }

    /// Attempt to start background compression. Returns true if compression was
    /// started, false if skipped (interval not elapsed, wrong backend type, etc.).
    pub fn start_compression(self: *BackendState, allocator: std.mem.Allocator, current_time_ns: u64) !bool {
        _ = current_time_ns;
        switch (self.backend) {
            .memory => return false,
            .logfile => |lf| {
                if (self.active_process != null) return false;

                const dir = lf.logfile_dir orelse return false;
                const path = lf.logfile_path orelse return false;

                if (dir.statFile("logfile.to_compress")) |_| {
                    std.log.warn("compression: skipping cycle, leftover logfile.to_compress still present", .{});
                    return false;
                } else |_| {}

                try std.fs.rename(dir, path, dir, "logfile.to_compress");

                const proc = try allocator.create(background.Process);
                errdefer allocator.destroy(proc);
                proc.* = .{ .allocator = allocator, .thread = null, .result = null, .mutex = .{}, .joined = false };

                proc.thread = try std.Thread.spawn(.{}, struct {
                    fn run(p: *background.Process, alloc: std.mem.Allocator, compress_dir: std.fs.Dir) void {
                        const r = background.compress(alloc, compress_dir, .{});
                        p.mutex.lock();
                        defer p.mutex.unlock();
                        p.result = r;
                    }
                }.run, .{ proc, allocator, dir });

                self.active_process = proc;
                return true;
            },
        }
    }

    /// Called after compression status is polled to allow the backend to clean up
    /// a completed process.
    pub fn finish_compression(self: *BackendState) void {
        const proc = self.active_process orelse return;
        switch (proc.status()) {
            .running => {},
            .success => {
                proc.deinit();
                self.active_process = null;
            },
            .failure => {
                std.log.debug("compression: background compression failed, retaining .to_compress for next cycle", .{});
                proc.deinit();
                self.active_process = null;
            },
        }
    }
};

test "MemoryPersistence load on empty backend returns empty slice" {
    var backend = PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = std.testing.allocator } };
    defer backend.deinit();

    const entries = try backend.load(std.testing.allocator);
    defer std.testing.allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "MemoryPersistence append then load returns stored bytes" {
    var backend = PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = std.testing.allocator } };
    defer backend.deinit();

    const data = [_]u8{ 0, 0, 4, 116, 111, 116, 111, 22, 71, 187, 92, 238, 225, 80, 0, 0 };
    try backend.append(&data);

    const entries = try backend.load(std.testing.allocator);
    defer {
        for (entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualSlices(u8, &data, entries[0]);
}

test "LogfilePersistence load on missing file returns empty slice" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var backend = PersistenceBackend{ .logfile = .{
        .logfile_path = "nonexistent.log",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    defer backend.deinit();

    const entries = try backend.load(allocator);
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "LogfilePersistence append then load returns stored entry" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var backend = PersistenceBackend{ .logfile = .{
        .logfile_path = "test.log",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    defer backend.deinit();

    const data = [_]u8{ 0, 0, 4, 116, 111, 116, 111, 22, 71, 187, 92, 238, 225, 80, 0, 0 };
    try backend.append(&data);

    const entries = try backend.load(allocator);
    defer {
        for (entries) |e| allocator.free(e);
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualSlices(u8, &data, entries[0]);
}

test "LogfilePersistence append multiple entries load returns all in order" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.debug.assert(status == .ok);
    }
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var backend = PersistenceBackend{ .logfile = .{
        .logfile_path = "test.log",
        .logfile_dir = tmp.dir,
        .load_arena = null,
        .fsync_on_persist = false,
    } };
    defer backend.deinit();

    const first = [_]u8{ 0, 0, 4, 116, 111, 116, 111, 22, 71, 187, 92, 238, 225, 80, 0, 0 };
    const second = [_]u8{ 0, 0, 5, 116, 97, 116, 97, 116, 22, 71, 187, 92, 238, 225, 80, 0, 2 };
    try backend.append(&first);
    try backend.append(&second);

    const entries = try backend.load(allocator);
    defer {
        for (entries) |e| allocator.free(e);
        allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualSlices(u8, &first, entries[0]);
    try std.testing.expectEqualSlices(u8, &second, entries[1]);
}

test "MemoryPersistence append multiple entries load returns all in order" {
    var backend = PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = std.testing.allocator } };
    defer backend.deinit();

    const first = [_]u8{ 0, 0, 4, 116, 111, 116, 111, 22, 71, 187, 92, 238, 225, 80, 0, 0 };
    const second = [_]u8{ 0, 0, 5, 116, 97, 116, 97, 116, 22, 71, 187, 92, 238, 225, 80, 0, 2 };
    const third = [_]u8{ 2, 0, 3, 102, 111, 111 };
    try backend.append(&first);
    try backend.append(&second);
    try backend.append(&third);

    const entries = try backend.load(std.testing.allocator);
    defer {
        for (entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualSlices(u8, &first, entries[0]);
    try std.testing.expectEqualSlices(u8, &second, entries[1]);
    try std.testing.expectEqualSlices(u8, &third, entries[2]);
}

test "MemoryPersistence stored bytes match encoder output" {
    const job = domain.job.Job{ .identifier = "toto", .execution = 1605457800_000000000, .status = .planned };
    const encoded = try encoder.encode(std.testing.allocator, .{ .job = job });
    defer std.testing.allocator.free(encoded);

    var backend = PersistenceBackend{ .memory = .{ .entries = .{}, .allocator = std.testing.allocator } };
    defer backend.deinit();

    try backend.append(encoded);

    const entries = try backend.load(std.testing.allocator);
    defer {
        for (entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualSlices(u8, encoded, entries[0]);
}
