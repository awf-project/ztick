const std = @import("std");
const logfile = @import("logfile.zig");
const encoder = @import("encoder.zig");
const domain = @import("../../domain.zig");

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

        const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(content);

        const parsed = try logfile.parse(allocator, content);
        return parsed.entries;
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
