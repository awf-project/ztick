pub const TelemetryConfig = struct {
    enabled: bool,
    endpoint: ?[]const u8,
    service_name: []const u8,
    flush_interval_ms: u32,
};
