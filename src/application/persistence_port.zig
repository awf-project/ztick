const std = @import("std");

pub const CompressionStatus = enum { idle, running, success, failure };

pub const PersistencePort = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        append_fn: *const fn (ctx: *anyopaque, entry: []const u8) anyerror!void,
        load_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![][]u8,
        reset_decode_arena_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator,
        deinit_fn: *const fn (ctx: *anyopaque) void,
        name_fn: *const fn (ctx: *anyopaque) []const u8,
        compression_status_fn: *const fn (ctx: *anyopaque) CompressionStatus,
        /// Attempt to start background compression. Returns true if compression was
        /// started, false if skipped (interval not elapsed, wrong backend type, etc.).
        start_compression_fn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, current_time_ns: u64) anyerror!bool,
        /// Called after compression status is polled to allow the backend to clean up
        /// a completed process.
        finish_compression_fn: *const fn (ctx: *anyopaque) void,
    };

    pub fn append(self: PersistencePort, entry: []const u8) !void {
        return self.vtable.append_fn(self.ptr, entry);
    }

    pub fn load(self: PersistencePort, allocator: std.mem.Allocator) ![][]u8 {
        return self.vtable.load_fn(self.ptr, allocator);
    }

    pub fn reset_decode_arena(self: PersistencePort, allocator: std.mem.Allocator) std.mem.Allocator {
        return self.vtable.reset_decode_arena_fn(self.ptr, allocator);
    }

    pub fn deinit(self: PersistencePort) void {
        return self.vtable.deinit_fn(self.ptr);
    }

    pub fn name(self: PersistencePort) []const u8 {
        return self.vtable.name_fn(self.ptr);
    }

    pub fn compression_status(self: PersistencePort) CompressionStatus {
        return self.vtable.compression_status_fn(self.ptr);
    }

    /// Returns true if compression was started, false if skipped.
    pub fn start_compression(self: PersistencePort, allocator: std.mem.Allocator, current_time_ns: u64) !bool {
        return self.vtable.start_compression_fn(self.ptr, allocator, current_time_ns);
    }

    pub fn finish_compression(self: PersistencePort) void {
        return self.vtable.finish_compression_fn(self.ptr);
    }
};
