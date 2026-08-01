const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allow the person running zig build to pick the architecture and OS
    const target = b.standardTargetOptions(.{});

    // Product binary: default to ReleaseFast, override with -Doptimize=Debug.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    const version = b.option(
        []const u8,
        "version",
        "Version string embedded into the outboxx binary",
    ) orelse "0.3.0";

    // Minimum log level compiled in. Default info keeps Release/prod output clean
    // (lower levels are filtered at comptime); the load stand builds with
    // -Dlog_level=debug to trace teardown / fail-fast behavior.
    const log_level = b.option(
        std.log.Level,
        "log_level",
        "Minimum log level compiled in: err, warn, info, debug (default: info)",
    ) orelse .info;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(std.log.Level, "log_level", log_level);

    // Static (musl) release binaries: the archives' transitive dependencies are
    // not discovered through .so metadata, so they must be linked explicitly.
    // pkg-config is bypassed too: it resolves to the dynamic libs in the dev
    // shell (and zig drops literal *.a paths from Libs), so static builds rely
    // on --search-prefix instead. Unreferenced archive members cost nothing.
    const static_deps = b.option(bool, "static-deps", "Link the C dependencies of libpq/librdkafka explicitly (static musl builds)") orelse false;
    const link_opts: std.Build.Module.LinkSystemLibraryOptions = if (static_deps) .{ .use_pkg_config = .no } else .{};
    // libpq needs pgcommon/pgport/ssl/crypto; librdkafka needs ssl/z/zstd.
    const static_dep_names = [_][]const u8{ "pgcommon", "pgport", "ssl", "crypto", "z", "zstd" };

    // TOML parser dependency (parses config straight into Zig structs)
    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });
    const toml_module = toml_dep.module("toml");

    // OpenTelemetry SDK: metric instruments + aggregation behind the observability facade.
    // It sets a preferred optimize mode, so it takes -Drelease, not -Doptimize; pass only target.
    const otel_dep = b.dependency("opentelemetry", .{ .target = target });
    const otel_module = otel_dep.module("sdk");

    // C bindings via build-system translate-c, split by deployment target so the
    // test-only mock cluster API never reaches the production binary. Each build
    // imports exactly one as "c", so the generated C types match within a build.
    //   prod = libpq + librdkafka
    //   dev  = prod + librdkafka's mock cluster (tests/benchmarks only)
    const c_prod = b.addTranslateC(.{
        .root_source_file = b.path("src/c/prod.h"),
        .target = target,
        .optimize = optimize,
    });
    addCHeadersT(b, c_prod);
    const c_prod_module = c_prod.createModule();

    const c_dev = b.addTranslateC(.{
        .root_source_file = b.path("src/c/dev.h"),
        .target = target,
        .optimize = optimize,
    });
    addCHeadersT(b, c_dev);
    const c_dev_module = c_dev.createModule();

    // Every internal source file is reached by relative path, so each binary is a
    // single module. The only named imports are external packages and the
    // generated build_options; addExternals wires them onto a module in one shot.
    // Registering one a file never imports is harmless: a module is analyzed only
    // when actually @imported. Tests/benchmarks get the dev "c" (mock cluster);
    // the product binaries get prod "c".
    const externals: Externals = .{
        .build_options = build_options,
        .toml = toml_module,
        .otel = otel_module,
    };

    // Main executable
    const exe = b.addExecutable(.{
        .name = "outboxx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = false, // Keep frame pointers for profiling
        }),
    });
    addExternals(exe.root_module, externals, c_prod_module);
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("pq", link_opts);
    exe.root_module.linkSystemLibrary("rdkafka", link_opts);
    if (static_deps) {
        for (static_dep_names) |name| exe.root_module.linkSystemLibrary(name, link_opts);
    }
    b.installArtifact(exe);

    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit tests (no external services)
    // Unit tests run as one aggregate binary rooted at src/unit_tests.zig; see
    // that file for why the suite is rooted at src/ instead of per test file.
    // source.zig reaches the libpq path (via replication_protocol), hence linkPg.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addExternals(unit_tests.root_module, externals, c_dev_module);
    linkPg(unit_tests.root_module);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Integration tests run as one aggregate binary rooted at integration_tests.zig
    // (repo root, see that file). They reach both the libpq and librdkafka paths.
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("integration_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addExternals(integration_tests.root_module, externals, c_dev_module);
    linkPg(integration_tests.root_module);
    linkKafka(integration_tests.root_module);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // E2E: full pipeline (PostgreSQL -> CDC -> Kafka). Links like the exe so
    // `zig build test-e2e -Dstatic-deps -Dtarget=*-musl` exercises the full suite
    // against the exact static release link set.
    const e2e_streaming_test = addUnitTest(b, "e2e_tests.zig", target, optimize, externals, c_dev_module);
    e2e_streaming_test.root_module.link_libc = true;
    e2e_streaming_test.root_module.linkSystemLibrary("pq", link_opts);
    e2e_streaming_test.root_module.linkSystemLibrary("rdkafka", link_opts);
    if (static_deps) {
        for (static_dep_names) |name| e2e_streaming_test.root_module.linkSystemLibrary(name, link_opts);
    }
    const run_e2e_streaming_test = b.addRunArtifact(e2e_streaming_test);
    const e2e_test_step = b.step("test-e2e", "Run end-to-end tests");
    e2e_test_step.dependOn(&run_e2e_streaming_test.step);

    // Development build with debug symbols and runtime safety
    const debug_exe = b.addExecutable(.{
        .name = "outboxx-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    addExternals(debug_exe.root_module, externals, c_prod_module);
    debug_exe.root_module.link_libc = true;
    debug_exe.root_module.linkSystemLibrary("pq", .{});
    debug_exe.root_module.linkSystemLibrary("rdkafka", .{});
    const debug_install = b.addInstallArtifact(debug_exe, .{});
    const debug_step = b.step("debug", "Build debug version");
    debug_step.dependOn(&debug_install.step);

    // Release build optimized for size
    const release_small_exe = b.addExecutable(.{
        .name = "outboxx-small",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });
    addExternals(release_small_exe.root_module, externals, c_prod_module);
    release_small_exe.root_module.link_libc = true;
    release_small_exe.root_module.linkSystemLibrary("pq", .{});
    release_small_exe.root_module.linkSystemLibrary("rdkafka", .{});
    const release_small_install = b.addInstallArtifact(release_small_exe, .{});
    const release_small_step = b.step("release-small", "Build release version optimized for size");
    release_small_step.dependOn(&release_small_install.step);

    // Static analysis with zig fmt check
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig" }, .check = true });
    const fmt_step = b.step("fmt-check", "Check code formatting");
    fmt_step.dependOn(&fmt_check.step);

    // Format code
    const fmt = b.addFmt(.{ .paths = &.{ "src", "build.zig" } });
    const fmt_fix_step = b.step("fmt", "Format code");
    fmt_fix_step.dependOn(&fmt.step);

    // Clean build artifacts. No std build step for a recursive delete, so shell out.
    const clean_step = b.step("clean", "Clean build artifacts");
    const remove_artifacts = b.addSystemCommand(&.{ "rm", "-rf", "zig-out", ".zig-cache" });
    clean_step.dependOn(&remove_artifacts.step);

    // Development workflow: format, test, and build
    const dev_step = b.step("dev", "Development workflow: format, test, and build");
    dev_step.dependOn(&fmt.step);
    dev_step.dependOn(&run_unit_tests.step);
    dev_step.dependOn(b.getInstallStep());

    // Benchmarks with zbench
    const zbench_dep = b.dependency("zbench", .{ .target = target, .optimize = .ReleaseFast });
    const zbench_module = zbench_dep.module("zbench");

    const serializer_bench = addBench(b, "serializer_bench", "serializer_bench_root.zig", target, externals, c_dev_module, zbench_module);
    const decoder_bench = addBench(b, "decoder_bench", "decoder_bench_root.zig", target, externals, c_dev_module, zbench_module);
    const match_streams_bench = addBench(b, "match_streams_bench", "match_streams_bench_root.zig", target, externals, c_dev_module, zbench_module);
    const partition_key_bench = addBench(b, "partition_key_bench", "partition_key_bench_root.zig", target, externals, c_dev_module, zbench_module);
    const converter_bench = addBench(b, "converter_bench", "converter_bench_root.zig", target, externals, c_dev_module, zbench_module);

    const kafka_bench = addBench(b, "kafka_bench", "kafka_bench_root.zig", target, externals, c_dev_module, zbench_module);
    linkKafka(kafka_bench.root_module);

    const bench_step = b.step("bench", "Compile component benchmarks");
    bench_step.dependOn(&b.addInstallArtifact(serializer_bench, .{}).step);
    bench_step.dependOn(&b.addInstallArtifact(decoder_bench, .{}).step);
    bench_step.dependOn(&b.addInstallArtifact(match_streams_bench, .{}).step);
    bench_step.dependOn(&b.addInstallArtifact(partition_key_bench, .{}).step);
    bench_step.dependOn(&b.addInstallArtifact(kafka_bench, .{}).step);
    bench_step.dependOn(&b.addInstallArtifact(converter_bench, .{}).step);
}

// External dependencies every internal module may reference by name.
const Externals = struct {
    build_options: *std.Build.Step.Options,
    toml: *std.Build.Module,
    otel: *std.Build.Module,
};

/// Wire the external packages and generated options onto a module. `c_module`
/// picks the translate-c variant (prod vs dev/mock).
fn addExternals(mod: *std.Build.Module, ext: Externals, c_module: *std.Build.Module) void {
    mod.addOptions("build_options", ext.build_options);
    mod.addImport("toml", ext.toml);
    mod.addImport("opentelemetry-sdk", ext.otel);
    mod.addImport("c", c_module);
}

fn addUnitTest(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ext: Externals,
    c_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }),
    });
    addExternals(t.root_module, ext, c_module);
    return t;
}

fn addBench(
    b: *std.Build,
    name: []const u8,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    ext: Externals,
    c_module: *std.Build.Module,
    zbench_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const t = b.addTest(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    addExternals(t.root_module, ext, c_module);
    t.root_module.addImport("zbench", zbench_module);
    return t;
}

fn linkPg(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.linkSystemLibrary("pq", .{});
}

fn linkKafka(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.linkSystemLibrary("rdkafka", .{});
}

/// Point a translate-c step at the system headers, from C_INCLUDE_PATH (set by
/// the Nix dev shell) with a system fallback.
fn addCHeadersT(b: *std.Build, translate_c: *std.Build.Step.TranslateC) void {
    if (b.graph.environ_map.get("C_INCLUDE_PATH")) |include_path| {
        var it = std.mem.splitScalar(u8, include_path, ':');
        while (it.next()) |path| {
            if (path.len > 0) {
                translate_c.addIncludePath(.{ .cwd_relative = path });
            }
        }
    } else {
        translate_c.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
    }
}
