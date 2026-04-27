const std = @import("std");
const sdk = @import("opentelemetry");
const config = @import("../interfaces/config.zig");
const version_info = @import("../version.zig");

pub const Span = sdk.api.trace.Span;

pub const TelemetryError = error{
    SetupFailed,
    ShutdownFailed,
};

/// Protobuf types extracted from the SDK's public Signal.Data union.
/// The SDK v0.1.1 trace OTLP exporter does not propagate resource attributes
/// to ResourceSpans (unlike the logs exporter). We need these types to build
/// the OTLP request ourselves with proper resource attributes.
const Pb = struct {
    fn unionPayload(comptime U: type, comptime name: []const u8) type {
        for (@typeInfo(U).@"union".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.type;
        }
        unreachable;
    }
    fn field(comptime S: type, comptime name: []const u8) type {
        for (@typeInfo(S).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.type;
        }
        unreachable;
    }
    fn child(comptime L: type) type {
        return @typeInfo(field(L, "items")).pointer.child;
    }
    fn unwrap(comptime O: type) type {
        return @typeInfo(O).optional.child;
    }

    const Request = unionPayload(sdk.otlp.Signal.Data, "traces");
    const ResourceSpans = child(field(Request, "resource_spans"));
    const ScopeSpans = child(field(ResourceSpans, "scope_spans"));
    const Resource = unwrap(field(ResourceSpans, "resource"));
    const PbSpan = child(field(ScopeSpans, "spans"));
    const KeyValue = child(field(Resource, "attributes"));
    const AnyValue = unwrap(field(KeyValue, "value"));
    const InstrScope = unwrap(field(ScopeSpans, "scope"));
    const EntityRef = child(field(Resource, "entity_refs"));
    const SpanEvent = child(field(PbSpan, "events"));
    const SpanLink = child(field(PbSpan, "links"));
    const SpanStatus = unwrap(field(PbSpan, "status"));
};

/// Custom OTLP span exporter that injects resource attributes into ResourceSpans.
/// Workaround for SDK v0.1.1 where the trace OTLPExporter sends empty resource attributes.
const ResourceAwareOTLPExporter = struct {
    allocator: std.mem.Allocator,
    otlp_config: *sdk.otlp.ConfigOptions,
    resource_attrs: ?[]const sdk.Attribute,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, otlp_config: *sdk.otlp.ConfigOptions, resource_attrs: ?[]const sdk.Attribute) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator, .otlp_config = otlp_config, .resource_attrs = resource_attrs };
        return self;
    }

    fn deinit(self: *Self) void {
        if (self.resource_attrs) |attrs| self.allocator.free(attrs);
        self.allocator.destroy(self);
    }

    fn asSpanExporter(self: *Self) sdk.trace.SpanExporter {
        return .{ .ptr = self, .vtable = &.{ .exportSpansFn = exportSpans, .shutdownFn = shutdownFn } };
    }

    fn shutdownFn(_: *anyopaque) anyerror!void {}

    fn exportSpans(ctx: *anyopaque, spans: []sdk.api.trace.Span) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (spans.len == 0) return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Group spans by instrumentation scope
        var scope_groups = std.HashMap(
            sdk.InstrumentationScope,
            std.ArrayList(sdk.api.trace.Span),
            sdk.InstrumentationScope.HashContext,
            std.hash_map.default_max_load_percentage,
        ).init(a);
        for (spans) |span| {
            const result = try scope_groups.getOrPut(span.scope);
            if (!result.found_existing) result.value_ptr.* = std.ArrayList(sdk.api.trace.Span){};
            try result.value_ptr.append(a, span);
        }

        // Build ScopeSpans
        var scope_spans_list = std.ArrayList(Pb.ScopeSpans){};
        var scope_iter = scope_groups.iterator();
        while (scope_iter.next()) |entry| {
            var otlp_spans = std.ArrayList(Pb.PbSpan){};
            for (entry.value_ptr.items) |span| {
                try otlp_spans.append(a, try spanToProto(a, span));
            }
            const scope_info = if (entry.value_ptr.items.len > 0) entry.value_ptr.items[0].scope else sdk.InstrumentationScope{ .name = "unknown" };
            var scope_attrs = std.ArrayList(Pb.KeyValue){};
            if (scope_info.attributes) |attrs| {
                for (attrs) |attr| try scope_attrs.append(a, attrToKeyValue(attr.key, attr.value));
            }
            try scope_spans_list.append(a, .{
                .scope = .{ .name = scope_info.name, .version = scope_info.version orelse "", .attributes = scope_attrs, .dropped_attributes_count = 0 },
                .spans = otlp_spans,
                .schema_url = scope_info.schema_url orelse "",
            });
        }

        // Build resource attributes
        var resource_kv = std.ArrayList(Pb.KeyValue){};
        if (self.resource_attrs) |attrs| {
            for (attrs) |attr| try resource_kv.append(a, attrToKeyValue(attr.key, attr.value));
        }

        var resource_spans = std.ArrayList(Pb.ResourceSpans){};
        try resource_spans.append(a, .{
            .resource = .{ .attributes = resource_kv, .dropped_attributes_count = 0, .entity_refs = std.ArrayList(Pb.EntityRef){} },
            .scope_spans = scope_spans_list,
            .schema_url = "",
        });

        const data = sdk.otlp.Signal.Data{ .traces = .{ .resource_spans = resource_spans } };
        return sdk.otlp.Export(a, self.otlp_config, data);
    }

    fn spanToProto(a: std.mem.Allocator, span: sdk.api.trace.Span) !Pb.PbSpan {
        const sc = span.span_context;
        const trace_id = try a.dupe(u8, &sc.trace_id.toBinary());
        const span_id = try a.dupe(u8, &sc.span_id.toBinary());

        var attrs = std.ArrayList(Pb.KeyValue){};
        for (span.attributes.keys(), span.attributes.values()) |key, value| {
            try attrs.append(a, attrToKeyValue(key, value));
        }

        var events = std.ArrayList(Pb.SpanEvent){};
        for (span.events.items) |event| {
            var ev_attrs = std.ArrayList(Pb.KeyValue){};
            for (event.attributes.keys(), event.attributes.values()) |key, value| {
                try ev_attrs.append(a, attrToKeyValue(key, value));
            }
            try events.append(a, .{ .time_unix_nano = event.timestamp, .name = event.name, .attributes = ev_attrs, .dropped_attributes_count = 0 });
        }

        var links = std.ArrayList(Pb.SpanLink){};
        for (span.links.items) |link| {
            var lk_attrs = std.ArrayList(Pb.KeyValue){};
            for (link.attributes.keys(), link.attributes.values()) |key, value| {
                try lk_attrs.append(a, attrToKeyValue(key, value));
            }
            try links.append(a, .{
                .trace_id = try a.dupe(u8, &link.span_context.trace_id.toBinary()),
                .span_id = try a.dupe(u8, &link.span_context.span_id.toBinary()),
                .trace_state = "",
                .attributes = lk_attrs,
                .dropped_attributes_count = 0,
                .flags = @intCast(link.span_context.trace_flags.value),
            });
        }

        var status: ?Pb.SpanStatus = null;
        if (span.status) |s| {
            status = .{
                .message = s.description,
                .code = switch (s.code) {
                    .Unset => @field(Pb.field(Pb.SpanStatus, "code"), "STATUS_CODE_UNSET"),
                    .Ok => @field(Pb.field(Pb.SpanStatus, "code"), "STATUS_CODE_OK"),
                    .Error => @field(Pb.field(Pb.SpanStatus, "code"), "STATUS_CODE_ERROR"),
                },
            };
        }

        return .{
            .trace_id = trace_id,
            .span_id = span_id,
            .trace_state = "",
            .parent_span_id = "",
            .flags = @intCast(sc.trace_flags.value),
            .name = span.name,
            .kind = switch (span.kind) {
                .Internal => @field(Pb.field(Pb.PbSpan, "kind"), "SPAN_KIND_INTERNAL"),
                .Server => @field(Pb.field(Pb.PbSpan, "kind"), "SPAN_KIND_SERVER"),
                .Client => @field(Pb.field(Pb.PbSpan, "kind"), "SPAN_KIND_CLIENT"),
                .Producer => @field(Pb.field(Pb.PbSpan, "kind"), "SPAN_KIND_PRODUCER"),
                .Consumer => @field(Pb.field(Pb.PbSpan, "kind"), "SPAN_KIND_CONSUMER"),
            },
            .start_time_unix_nano = span.start_time_unix_nano,
            .end_time_unix_nano = span.end_time_unix_nano,
            .attributes = attrs,
            .dropped_attributes_count = 0,
            .events = events,
            .dropped_events_count = 0,
            .links = links,
            .dropped_links_count = 0,
            .status = status,
        };
    }

    fn attrToKeyValue(key: []const u8, value: sdk.AttributeValue) Pb.KeyValue {
        return .{
            .key = key,
            .value = switch (value) {
                .string => |v| Pb.AnyValue{ .value = .{ .string_value = v } },
                .bool => |v| Pb.AnyValue{ .value = .{ .bool_value = v } },
                .int => |v| Pb.AnyValue{ .value = .{ .int_value = v } },
                .double => |v| Pb.AnyValue{ .value = .{ .double_value = v } },
                .baggage => unreachable,
            },
        };
    }
};

pub const Providers = struct {
    allocator: std.mem.Allocator,
    meter_provider: *sdk.metrics.MeterProvider,
    metric_reader: *sdk.metrics.MetricReader,
    metric_otlp: *sdk.metrics.OTLPExporter,
    tracer_provider: *sdk.trace.TracerProvider,
    trace_processor: sdk.trace.SimpleProcessor,
    trace_otlp: *ResourceAwareOTLPExporter,
    logger_provider: *sdk.logs.LoggerProvider,
    log_processor: sdk.logs.SimpleLogRecordProcessor,
    log_otlp: *sdk.logs.OTLPExporter,
    otlp_config: *sdk.otlp.ConfigOptions,

    pub fn shutdown(self: *Providers) void {
        sdk.logs.std_log_bridge.shutdown();
        self.logger_provider.deinit();
        self.log_otlp.deinit();
        self.tracer_provider.shutdown();
        self.trace_otlp.deinit();
        self.metric_reader.shutdown();
        self.metric_otlp.deinit();
        self.meter_provider.shutdown();
        self.otlp_config.deinit();
        self.allocator.destroy(self);
    }
};

pub fn setup(allocator: std.mem.Allocator, cfg: config.TelemetryConfig) !?*Providers {
    if (!cfg.enabled) return null;

    const endpoint_url = cfg.endpoint orelse return error.SetupFailed;

    const otlp_config = try sdk.otlp.ConfigOptions.init(allocator);
    errdefer otlp_config.deinit();
    otlp_config.protocol = .http_protobuf;
    otlp_config.timeout_sec = 2;
    otlp_config.retryConfig = .{ .max_retries = 0, .base_delay_ms = 100, .max_delay_ms = 1000 };
    if (std.mem.startsWith(u8, endpoint_url, "https://")) {
        otlp_config.scheme = .https;
        otlp_config.endpoint = endpoint_url["https://".len..];
    } else if (std.mem.startsWith(u8, endpoint_url, "http://")) {
        otlp_config.scheme = .http;
        otlp_config.endpoint = endpoint_url["http://".len..];
    } else {
        otlp_config.endpoint = endpoint_url;
    }

    const metric_otlp = try sdk.metrics.OTLPExporter.init(allocator, otlp_config, sdk.metrics.View.DefaultTemporality);
    errdefer metric_otlp.deinit();

    const metric_exporter = try sdk.metrics.MetricExporter.new(allocator, &metric_otlp.exporter);

    const meter_provider = try sdk.metrics.MeterProvider.init(allocator);
    errdefer meter_provider.shutdown();

    const metric_reader = try sdk.metrics.MetricReader.init(allocator, metric_exporter);
    errdefer metric_reader.shutdown();

    try meter_provider.addReader(metric_reader);

    // Build resource attributes for service identification
    const resource_attrs = try sdk.attributes.Attributes.from(allocator, .{
        "service.name",    @as([]const u8, cfg.service_name),
        "service.version", @as([]const u8, version_info.version),
    });

    const trace_otlp = try ResourceAwareOTLPExporter.init(allocator, otlp_config, resource_attrs);
    errdefer trace_otlp.deinit();

    const tracer_provider = try sdk.trace.TracerProvider.init(
        allocator,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init(std.crypto.random) },
    );
    errdefer tracer_provider.shutdown();

    const log_otlp = try sdk.logs.OTLPExporter.init(allocator, otlp_config);
    errdefer log_otlp.deinit();

    const logger_provider = try sdk.logs.LoggerProvider.init(allocator, null);
    errdefer logger_provider.deinit();

    const providers = try allocator.create(Providers);
    errdefer allocator.destroy(providers);

    providers.* = Providers{
        .allocator = allocator,
        .meter_provider = meter_provider,
        .metric_reader = metric_reader,
        .metric_otlp = metric_otlp,
        .tracer_provider = tracer_provider,
        .trace_processor = sdk.trace.SimpleProcessor.init(allocator, trace_otlp.asSpanExporter()),
        .trace_otlp = trace_otlp,
        .logger_provider = logger_provider,
        .log_processor = sdk.logs.SimpleLogRecordProcessor.init(allocator, log_otlp.asLogRecordExporter()),
        .log_otlp = log_otlp,
        .otlp_config = otlp_config,
    };

    // Trace and log processors are NOT registered here — they export synchronously
    // via OTLP HTTP which blocks on network I/O. Callers (main.zig) register them
    // after ensuring the endpoint is reachable or in production context.
    // providers.trace_processor and providers.log_processor are available for
    // explicit registration via addSpanProcessor/addLogRecordProcessor.

    return providers;
}

pub const Instruments = struct {
    jobs_scheduled: *sdk.metrics.Counter(u64),
    jobs_executed: *sdk.metrics.Counter(u64),
    jobs_removed: *sdk.metrics.Counter(u64),
    persistence_compactions: *sdk.metrics.Counter(u64),
    execution_duration_ms: *sdk.metrics.Histogram(f64),
    rules_active: *sdk.metrics.UpDownCounter(i64),
    connections_active: *sdk.metrics.UpDownCounter(i64),
    tracer: *sdk.api.trace.TracerImpl,
};

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
    const meter_provider = try sdk.metrics.MeterProvider.init(std.testing.allocator);
    defer meter_provider.shutdown();
    const tracer_provider = try sdk.trace.TracerProvider.init(
        std.testing.allocator,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init(std.crypto.random) },
    );
    defer tracer_provider.shutdown();
    const instruments = try createInstruments(meter_provider, tracer_provider);
    _ = instruments;
}

test "createInstruments returns callable counter and histogram instruments" {
    const meter_provider = try sdk.metrics.MeterProvider.init(std.testing.allocator);
    defer meter_provider.shutdown();
    const tracer_provider = try sdk.trace.TracerProvider.init(
        std.testing.allocator,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init(std.crypto.random) },
    );
    defer tracer_provider.shutdown();
    const instruments = try createInstruments(meter_provider, tracer_provider);
    try instruments.jobs_scheduled.add(1, .{});
    try instruments.jobs_executed.add(1, .{});
    try instruments.jobs_removed.add(1, .{});
    try instruments.persistence_compactions.add(1, .{});
    try instruments.execution_duration_ms.record(42.5, .{});
}

test "createInstruments returns callable up-down counter instruments" {
    const meter_provider = try sdk.metrics.MeterProvider.init(std.testing.allocator);
    defer meter_provider.shutdown();
    const tracer_provider = try sdk.trace.TracerProvider.init(
        std.testing.allocator,
        sdk.trace.IDGenerator{ .Random = sdk.trace.RandomIDGenerator.init(std.crypto.random) },
    );
    defer tracer_provider.shutdown();
    const instruments = try createInstruments(meter_provider, tracer_provider);
    try instruments.rules_active.add(1, .{});
    try instruments.rules_active.add(-1, .{});
    try instruments.connections_active.add(1, .{});
    try instruments.connections_active.add(-1, .{});
}

test "setup returns null when telemetry is disabled" {
    const cfg = config.TelemetryConfig{
        .enabled = false,
        .endpoint = null,
        .service_name = "ztick",
        .flush_interval_ms = 5000,
    };
    const result = try setup(std.testing.allocator, cfg);
    try std.testing.expectEqual(@as(?*Providers, null), result);
}

test "setup returns initialized providers when telemetry is enabled" {
    const endpoint = "http://localhost:4318";
    const cfg = config.TelemetryConfig{
        .enabled = true,
        .endpoint = endpoint,
        .service_name = "ztick",
        .flush_interval_ms = 5000,
    };
    const providers = try setup(std.testing.allocator, cfg);
    try std.testing.expect(providers != null);
    providers.?.shutdown();
}

test "setup with custom flush interval initializes without error" {
    const endpoint = "http://collector:4318";
    const cfg = config.TelemetryConfig{
        .enabled = true,
        .endpoint = endpoint,
        .service_name = "my-service",
        .flush_interval_ms = 10000,
    };
    const providers = try setup(std.testing.allocator, cfg);
    try std.testing.expect(providers != null);
    providers.?.shutdown();
}
