const std = @import("std");

fn link_openssl(step: *std.Build.Step.Compile) void {
    step.linkLibC();
    step.linkSystemLibrary("ssl");
    step.linkSystemLibrary("crypto");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Link OpenSSL only when tls_context.zig is present; plaintext-only builds remain zero-dependency.
    const tls_enabled = blk: {
        b.build_root.handle.access("src/infrastructure/tls_context.zig", .{}) catch break :blk false;
        break :blk true;
    };

    // OpenTelemetry SDK dependency (ADR-0004)
    const otel_dep = b.dependency("opentelemetry", .{
        .target = target,
        .optimize = optimize,
    });
    const otel_module = otel_dep.module("sdk");

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("opentelemetry", otel_module);

    const exe = b.addExecutable(.{
        .name = "ztick",
        .root_module = root_module,
    });
    if (tls_enabled) link_openssl(exe);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ztick");
    run_step.dependOn(&run_cmd.step);

    // Per-layer test steps
    const layer_tests = [_]struct { name: []const u8, desc: []const u8, path: []const u8 }{
        .{ .name = "test-domain", .desc = "Run domain layer tests", .path = "src/domain.zig" },
        .{ .name = "test-application", .desc = "Run application layer tests", .path = "src/application.zig" },
        .{ .name = "test-infrastructure", .desc = "Run infrastructure layer tests", .path = "src/infrastructure.zig" },
        .{ .name = "test-interfaces", .desc = "Run interfaces layer tests", .path = "src/interfaces.zig" },
    };

    // "test" step: all layers + main.zig integration tests
    const test_step = b.step("test", "Run all unit tests");
    for (layer_tests) |layer| {
        const layer_module = b.createModule(.{
            .root_source_file = b.path(layer.path),
            .target = target,
            .optimize = optimize,
        });
        layer_module.addImport("opentelemetry", otel_module);
        const layer_test = b.addTest(.{ .root_module = layer_module });
        if (tls_enabled and std.mem.eql(u8, layer.name, "test-infrastructure")) link_openssl(layer_test);
        const run_layer_test = b.addRunArtifact(layer_test);
        test_step.dependOn(&run_layer_test.step);
        const step = b.step(layer.name, layer.desc);
        step.dependOn(&run_layer_test.step);
    }
    // main.zig integration tests
    const main_test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_test_module.addImport("opentelemetry", otel_module);
    const main_tests = b.addTest(.{ .root_module = main_test_module });
    if (tls_enabled) link_openssl(main_tests);
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Functional tests
    const functional_module = b.createModule(.{
        .root_source_file = b.path("src/functional_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    functional_module.addImport("opentelemetry", otel_module);
    const functional_test = b.addTest(.{
        .root_module = functional_module,
    });
    if (tls_enabled) link_openssl(functional_test);
    const run_functional = b.addRunArtifact(functional_test);
    const functional_step = b.step("test-functional", "Run functional tests");
    functional_step.dependOn(&run_functional.step);

    // test-all: unit + functional
    const test_all_step = b.step("test-all", "Run all unit and functional tests");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(&run_functional.step);

    // Format check
    const fmt = b.addFmt(.{ .paths = &.{"src"} });
    const fmt_step = b.step("fmt", "Format source files");
    fmt_step.dependOn(&fmt.step);

    const fmt_check = b.addFmt(.{ .paths = &.{"src"}, .check = true });
    const fmt_check_step = b.step("fmt-check", "Check source formatting");
    fmt_check_step.dependOn(&fmt_check.step);
}
