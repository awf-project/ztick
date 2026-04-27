// Single source of truth for the ztick version: build.zig.zon. `build.zig`
// reads `.version` from the ZON manifest and exposes it through `build_options`,
// so every consumer (CLI --version, telemetry resource attributes, OpenAPI spec)
// sees the same value.
pub const version = @import("build_options").version;
