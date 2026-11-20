const std = @import("std");
const sdk = @import("opentelemetry");
const domain = @import("../domain.zig");
const version_info = @import("../version.zig");
const app_instruments = @import("../application/instruments.zig");

/// Re-exported from application/instruments.zig to avoid application → infrastructure imports.
pub const Span = app_instruments.Span;
/// Re-exported from application/instruments.zig to avoid application → infrastructure imports.
pub const Instruments = app_instruments.Instruments;

pub const TelemetryError = error{
    SetupFailed,
    ShutdownFailed,
};

pub const Providers = struct {
    allocator: std.mem.Allocator,
    meter_provider: *sdk.metrics.MeterProvider,
    metric_reader: *sdk.metrics.MetricReader,
    metric_otlp: *sdk.metrics.OTLPExporter,
    tracer_provider: *sdk.trace.TracerProvider,
    trace_processor: sdk.trace.SimpleProcessor,
    trace_otlp: *sdk.trace.OTLPExporter,
    logger_provider: *sdk.logs.LoggerProvider,
    log_processor: sdk.logs.SimpleLogRecordProcessor,
    log_otlp: *sdk.logs.OTLPExporter,
    otlp_config: *sdk.otlp.ConfigOptions,
    io_rng: std.Random.IoSource,

    pub fn shutdown(self: *Providers) void {
        sdk.logs.std_log_bridge.shutdown();
        self.logger_provider.deinit();
        self.log_otlp.deinit();
        self.tracer_provider.deinit();
        self.trace_otlp.deinit();
        // ztick collects metrics explicitly. Keep teardown independent of collector availability.
        self.meter_provider.detachReader(self.metric_reader);
        self.metric_reader.deinit();
        self.metric_otlp.deinit();
        self.meter_provider.deinit();
        self.otlp_config.deinit();
        self.allocator.destroy(self);
    }
};

pub fn setup(allocator: std.mem.Allocator, cfg: domain.telemetry_config.TelemetryConfig, env_map: *const std.process.Environ.Map, io: std.Io) !?*Providers {
    if (!cfg.enabled) return null;

    const endpoint_url = cfg.endpoint orelse return error.SetupFailed;

    var exporter_env = try env_map.clone(allocator);
    defer exporter_env.deinit();
    try exporter_env.put("OTEL_EXPORTER_OTLP_ENDPOINT", endpoint_url);
    const otlp_config = try sdk.otlp.ConfigOptions.init(allocator, &exporter_env);
    errdefer otlp_config.deinit();
    otlp_config.protocol = .http_protobuf;
    otlp_config.timeout_sec = 2;
    otlp_config.retryConfig = .{ .max_retries = 0, .base_delay_ms = 100, .max_delay_ms = 1000 };
    const metric_otlp = try sdk.metrics.OTLPExporter.init(allocator, io, sdk.metrics.View.DefaultTemporality, otlp_config);
    errdefer metric_otlp.deinit();

    const meter_provider = try sdk.metrics.MeterProvider.init(allocator, io);
    errdefer meter_provider.deinit();

    const metric_exporter = try sdk.metrics.MetricExporter.new(allocator, io, &metric_otlp.exporter);
    const metric_reader = sdk.metrics.MetricReader.init(allocator, io, metric_exporter) catch |err| {
        metric_exporter.shutdown();
        return err;
    };
    errdefer metric_reader.deinit();

    const trace_otlp = try sdk.trace.OTLPExporter.init(allocator, io, otlp_config);
    errdefer trace_otlp.deinit();

    const providers = try allocator.create(Providers);
    errdefer allocator.destroy(providers);
    providers.io_rng = std.Random.IoSource{ .io = io };

    const tracer_provider = try sdk.trace.TracerProvider.init(
        allocator,
        io,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init(providers.io_rng.interface()) },
    );
    errdefer tracer_provider.deinit();

    const service_attributes = [_]sdk.Attribute{
        .{ .key = "service.name", .value = .{ .string = cfg.service_name } },
        .{ .key = "service.version", .value = .{ .string = version_info.version } },
    };
    const previous_resource = tracer_provider.resource;
    tracer_provider.resource = try sdk.resource.mergeResources(allocator, &service_attributes, previous_resource orelse &.{});
    if (previous_resource) |attrs| sdk.resource.freeResource(allocator, attrs);

    const log_otlp = try sdk.logs.OTLPExporter.init(allocator, io, otlp_config);
    errdefer log_otlp.deinit();

    const logger_provider = try sdk.logs.LoggerProvider.init(allocator, io, null);
    errdefer logger_provider.deinit();

    try meter_provider.addReader(metric_reader);

    providers.allocator = allocator;
    providers.meter_provider = meter_provider;
    providers.metric_reader = metric_reader;
    providers.metric_otlp = metric_otlp;
    providers.tracer_provider = tracer_provider;
    providers.trace_processor = sdk.trace.SimpleProcessor.init(allocator, io, trace_otlp.asSpanExporter());
    providers.trace_otlp = trace_otlp;
    providers.logger_provider = logger_provider;
    providers.log_processor = sdk.logs.SimpleLogRecordProcessor.init(io, log_otlp.asLogRecordExporter());
    providers.log_otlp = log_otlp;
    providers.otlp_config = otlp_config;

    // Trace and log processors are NOT registered here — they export synchronously
    // via OTLP HTTP which blocks on network I/O. Callers (main.zig) register them
    // after ensuring the endpoint is reachable or in production context.
    // providers.trace_processor and providers.log_processor are available for
    // explicit registration via addSpanProcessor/addLogRecordProcessor.

    return providers;
}

pub fn createInstruments(meter_provider: *sdk.metrics.MeterProvider, tracer_provider: *sdk.trace.TracerProvider) !Instruments {
    const meter = try meter_provider.getMeter(.{ .name = "ztick" });
    const tracer = try tracer_provider.getTracer(.{ .name = "ztick" });
    return Instruments{
        .jobs_scheduled = try meter.createCounter(u64, .{ .name = "jobs_scheduled" }),
        .jobs_executed = try meter.createCounter(u64, .{ .name = "jobs_executed" }),
        .jobs_removed = try meter.createCounter(u64, .{ .name = "jobs_removed" }),
        .persistence_compactions = try meter.createCounter(u64, .{ .name = "persistence_compactions" }),
        .execution_duration_ms = try meter.createHistogram(f64, .{ .name = "execution_duration_ms" }),
        .rules_active = try meter.createUpDownCounter(i64, .{ .name = "rules_active" }),
        .connections_active = try meter.createUpDownCounter(i64, .{ .name = "connections_active" }),
        .tracer = tracer,
    };
}

test "createInstruments succeeds with valid meter and tracer providers" {
    const meter_provider = try sdk.metrics.MeterProvider.init(std.testing.allocator, std.testing.io);
    defer meter_provider.deinit();
    const io_rng = std.Random.IoSource{ .io = std.testing.io };
    const tracer_provider = try sdk.trace.TracerProvider.init(
        std.testing.allocator,
        std.testing.io,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init(io_rng.interface()) },
    );
    defer tracer_provider.deinit();
    const instruments = try createInstruments(meter_provider, tracer_provider);
    _ = instruments;
}

test "createInstruments returns callable counter and histogram instruments" {
    const meter_provider = try sdk.metrics.MeterProvider.init(std.testing.allocator, std.testing.io);
    defer meter_provider.deinit();
    const io_rng = std.Random.IoSource{ .io = std.testing.io };
    const tracer_provider = try sdk.trace.TracerProvider.init(
        std.testing.allocator,
        std.testing.io,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init(io_rng.interface()) },
    );
    defer tracer_provider.deinit();
    const instruments = try createInstruments(meter_provider, tracer_provider);
    try instruments.jobs_scheduled.add(1, .{});
    try instruments.jobs_executed.add(1, .{});
    try instruments.jobs_removed.add(1, .{});
    try instruments.persistence_compactions.add(1, .{});
    try instruments.execution_duration_ms.record(42.5, .{});
}

test "createInstruments returns callable up-down counter instruments" {
    const meter_provider = try sdk.metrics.MeterProvider.init(std.testing.allocator, std.testing.io);
    defer meter_provider.deinit();
    const io_rng = std.Random.IoSource{ .io = std.testing.io };
    const tracer_provider = try sdk.trace.TracerProvider.init(
        std.testing.allocator,
        std.testing.io,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init(io_rng.interface()) },
    );
    defer tracer_provider.deinit();
    const instruments = try createInstruments(meter_provider, tracer_provider);
    try instruments.rules_active.add(1, .{});
    try instruments.rules_active.add(-1, .{});
    try instruments.connections_active.add(1, .{});
    try instruments.connections_active.add(-1, .{});
}

test "setup returns null when telemetry is disabled" {
    const cfg = domain.telemetry_config.TelemetryConfig{
        .enabled = false,
        .endpoint = null,
        .service_name = "ztick",
        .flush_interval_ms = 5000,
    };
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const result = try setup(std.testing.allocator, cfg, &env_map, std.testing.io);
    try std.testing.expectEqual(@as(?*Providers, null), result);
}

test "setup returns initialized providers when telemetry is enabled" {
    const endpoint = "http://localhost:4318";
    const cfg = domain.telemetry_config.TelemetryConfig{
        .enabled = true,
        .endpoint = endpoint,
        .service_name = "ztick",
        .flush_interval_ms = 5000,
    };
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_EXPORTER_OTLP_ENDPOINT", "https://other.example:443");
    const providers = (try setup(std.testing.allocator, cfg, &env_map, std.testing.io)).?;
    defer providers.shutdown();
    try std.testing.expectEqualStrings("localhost:4318", providers.otlp_config.endpoint);
    try std.testing.expectEqual(.http, providers.otlp_config.scheme);
    try std.testing.expectEqualStrings("https://other.example:443", env_map.get("OTEL_EXPORTER_OTLP_ENDPOINT").?);

    const tracer = try providers.tracer_provider.getTracer(.{ .name = "ztick" });
    var span = try tracer.startSpan(std.testing.allocator, "request", .{});
    defer span.deinit();
    defer span.end(null);
    const attributes = span.resource orelse return error.MissingResource;
    for ([_]sdk.Attribute{
        .{ .key = "service.name", .value = .{ .string = cfg.service_name } },
        .{ .key = "service.version", .value = .{ .string = version_info.version } },
    }) |expected| {
        for (attributes) |attr| {
            if (std.mem.eql(u8, attr.key, expected.key)) {
                try std.testing.expectEqualStrings(expected.value.string, attr.value.string);
                break;
            }
        } else return error.MissingServiceAttribute;
    }
}

test "setup with custom flush interval initializes without error" {
    const endpoint = "http://collector:4318";
    const cfg = domain.telemetry_config.TelemetryConfig{
        .enabled = true,
        .endpoint = endpoint,
        .service_name = "my-service",
        .flush_interval_ms = 10000,
    };
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    const providers = try setup(std.testing.allocator, cfg, &env_map, std.testing.io);
    try std.testing.expect(providers != null);
    providers.?.shutdown();
}
