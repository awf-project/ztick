const std = @import("std");
const encoder = @import("encoder.zig");
const logfile = @import("logfile.zig");

pub const TaskError = error{Failure};
pub const TaskResult = TaskError!void;

pub const Status = union(enum) {
    success,
    failure: TaskError,
    running,
};

pub const Process = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    result: ?TaskResult,
    mutex: std.Thread.Mutex,

    pub fn execute(allocator: std.mem.Allocator, task: anytype) !*Process {
        const proc = try allocator.create(Process);
        proc.* = .{ .allocator = allocator, .thread = undefined, .result = null, .mutex = .{} };
        proc.thread = try std.Thread.spawn(.{}, struct {
            fn run(p: *Process, t: @TypeOf(task)) void {
                const r = t();
                p.mutex.lock();
                defer p.mutex.unlock();
                p.result = r;
            }
        }.run, .{ proc, task });
        return proc;
    }

    pub fn deinit(self: *Process) void {
        self.allocator.destroy(self);
    }

    pub fn status(self: *Process) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        const r = self.result orelse return .running;
        if (r) |_| return .success else |err| return .{ .failure = err };
    }
};

pub const Filenames = struct {
    source: []const u8 = "logfile.to_compress",
    tmp: []const u8 = "logfile.compressed.tmp",
    dest: []const u8 = "logfile.compressed",
};

pub fn compress(allocator: std.mem.Allocator, dir: std.fs.Dir, filenames: Filenames) TaskResult {
    const content = dir.readFileAlloc(
        allocator,
        filenames.source,
        std.math.maxInt(usize),
    ) catch return error.Failure;
    defer allocator.free(content);

    const parsed = logfile.parse(allocator, content) catch return error.Failure;
    defer {
        for (parsed.entries) |e| allocator.free(e);
        allocator.free(parsed.entries);
    }

    const entry_ids = allocator.alloc(?[]const u8, parsed.entries.len) catch return error.Failure;
    defer {
        for (entry_ids) |maybe_id| if (maybe_id) |id| allocator.free(id);
        allocator.free(entry_ids);
    }

    var last_index = std.StringHashMap(usize).init(allocator);
    defer last_index.deinit();

    for (parsed.entries, 0..) |entry, i| {
        const decoded = encoder.decode(allocator, entry) catch {
            entry_ids[i] = null;
            continue;
        };
        encoder.free_entry_fields(decoded, allocator);
        const id = switch (decoded) {
            .job => |j| j.identifier,
            .rule => |r| r.identifier,
        };
        entry_ids[i] = id;
        last_index.put(id, i) catch return error.Failure;
    }

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    for (parsed.entries, 0..) |entry, i| {
        const maybe_id = entry_ids[i];
        if (maybe_id) |id| {
            const last = last_index.get(id) orelse continue;
            if (last != i) continue;
        }
        const framed = logfile.encode(allocator, entry) catch return error.Failure;
        defer allocator.free(framed);
        out.appendSlice(allocator, framed) catch return error.Failure;
    }

    {
        const f = dir.createFile(filenames.tmp, .{}) catch return error.Failure;
        defer f.close();
        f.writeAll(out.items) catch return error.Failure;
    }
    dir.rename(filenames.tmp, filenames.dest) catch return error.Failure;
    dir.deleteFile(filenames.source) catch return error.Failure;
}

test "execute successful task reports success" {
    var proc = try Process.execute(std.testing.allocator, struct {
        fn run() TaskResult {
            return {};
        }
    }.run);
    proc.thread.join();
    try std.testing.expectEqual(Status.success, proc.status());
    proc.deinit();
}

test "execute failing task reports failure" {
    var proc = try Process.execute(std.testing.allocator, struct {
        fn run() TaskResult {
            return error.Failure;
        }
    }.run);
    proc.thread.join();
    try std.testing.expect(proc.status() == .failure);
    proc.deinit();
}

test "status returns running before task completes" {
    const Gate = struct {
        var gate = std.atomic.Value(bool).init(false);
        fn task() TaskResult {
            while (!gate.load(.acquire)) {
                std.Thread.sleep(1_000);
            }
            return {};
        }
    };
    Gate.gate.store(false, .release);
    var proc = try Process.execute(std.testing.allocator, Gate.task);
    const s = proc.status();
    Gate.gate.store(true, .release);
    proc.thread.join();
    try std.testing.expectEqual(Status.running, s);
    proc.deinit();
}

test "compress succeeds with empty logfile.to_compress" {
    const default_filenames: Filenames = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try tmp.dir.createFile(default_filenames.source, .{});
    f.close();

    try compress(std.testing.allocator, tmp.dir, default_filenames);

    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(default_filenames.source));
    _ = try tmp.dir.statFile(default_filenames.dest);
}

test "compress deduplicates entries keeping latest" {
    const default_filenames: Filenames = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entry1_raw = try encoder.encode(std.testing.allocator, .{ .job = .{
        .identifier = "job1",
        .execution = 100,
        .status = .planned,
    } });
    defer std.testing.allocator.free(entry1_raw);
    const entry2_raw = try encoder.encode(std.testing.allocator, .{ .job = .{
        .identifier = "job1",
        .execution = 200,
        .status = .triggered,
    } });
    defer std.testing.allocator.free(entry2_raw);

    const framed1 = try logfile.encode(std.testing.allocator, entry1_raw);
    defer std.testing.allocator.free(framed1);
    const framed2 = try logfile.encode(std.testing.allocator, entry2_raw);
    defer std.testing.allocator.free(framed2);

    {
        const f = try tmp.dir.createFile(default_filenames.source, .{});
        defer f.close();
        try f.writeAll(framed1);
        try f.writeAll(framed2);
    }

    try compress(std.testing.allocator, tmp.dir, default_filenames);

    const compressed = try tmp.dir.readFileAlloc(std.testing.allocator, default_filenames.dest, 1024 * 1024);
    defer std.testing.allocator.free(compressed);
    const parsed = try logfile.parse(std.testing.allocator, compressed);
    defer {
        for (parsed.entries) |e| std.testing.allocator.free(e);
        std.testing.allocator.free(parsed.entries);
    }
    try std.testing.expectEqual(@as(usize, 1), parsed.entries.len);
}
