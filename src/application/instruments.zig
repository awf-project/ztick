const sdk = @import("opentelemetry");

pub const Span = sdk.api.trace.Span;

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
