const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allow the person running zig build to pick the architecture and OS
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running zig build to pick the optimization level
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "outboxx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link libc for PostgreSQL and Kafka C libraries
    exe.linkLibC();

    // Add PostgreSQL library (libpq)
    exe.linkSystemLibrary("pq");

    // Add Kafka library (librdkafka)
    exe.linkSystemLibrary("rdkafka");

    // Add include paths from environment (useful for Nix and custom installs)
    if (std.process.getEnvVarOwned(b.allocator, "C_INCLUDE_PATH")) |include_path| {
        defer b.allocator.free(include_path);
        var it = std.mem.splitScalar(u8, include_path, ':');
        while (it.next()) |path| {
            if (path.len > 0) {
                exe.addIncludePath(.{ .cwd_relative = path });
            }
        }
    } else |_| {
        // Fallback to standard system paths
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
    }

    b.installArtifact(exe);


    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Allow passing arguments to the application
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit tests - test all *_test.zig files
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const wal_reader_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wal/reader_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wal_reader_tests.linkLibC();
    wal_reader_tests.linkSystemLibrary("pq");

    // Message processor tests
    const message_processor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/message_processor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Kafka producer tests (need both libpq and librdkafka for integration)
    const kafka_producer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kafka/producer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kafka_producer_tests.linkLibC();
    kafka_producer_tests.linkSystemLibrary("rdkafka");

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_wal_reader_tests = b.addRunArtifact(wal_reader_tests);
    const run_message_processor_tests = b.addRunArtifact(message_processor_tests);
    const run_kafka_producer_tests = b.addRunArtifact(kafka_producer_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_wal_reader_tests.step);
    test_step.dependOn(&run_message_processor_tests.step);
    test_step.dependOn(&run_kafka_producer_tests.step);

    // Integration tests (moved to src/ for simplicity)
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.linkLibC();
    integration_tests.linkSystemLibrary("pq");
    integration_tests.linkSystemLibrary("rdkafka");

    // Kafka integration tests (in kafka directory)
    const kafka_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kafka/producer_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kafka_integration_tests.linkLibC();
    kafka_integration_tests.linkSystemLibrary("rdkafka");

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const run_kafka_integration_tests = b.addRunArtifact(kafka_integration_tests);

    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);
    integration_test_step.dependOn(&run_kafka_integration_tests.step);

    // Single integration test with filter
    const single_integration_test = b.addRunArtifact(integration_tests);
    if (b.args) |args| {
        single_integration_test.addArgs(args);
    }
    const single_integration_test_step = b.step("test-single", "Run single integration test with --test-filter");
    single_integration_test_step.dependOn(&single_integration_test.step);

    // Development build with debug symbols and runtime safety
    const debug_exe = b.addExecutable(.{
        .name = "outboxx-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    debug_exe.linkLibC();
    debug_exe.linkSystemLibrary("pq");

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
    release_small_exe.linkLibC();
    release_small_exe.linkSystemLibrary("pq");

    const release_small_install = b.addInstallArtifact(release_small_exe, .{});
    const release_small_step = b.step("release-small", "Build release version optimized for size");
    release_small_step.dependOn(&release_small_install.step);

    // Static analysis with zig fmt check
    const fmt_check = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
        .check = true,
    });
    const fmt_step = b.step("fmt-check", "Check code formatting");
    fmt_step.dependOn(&fmt_check.step);

    // Format code
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig" },
    });
    const fmt_fix_step = b.step("fmt", "Format code");
    fmt_fix_step.dependOn(&fmt.step);

    // Clean build artifacts
    const clean_step = b.step("clean", "Clean build artifacts");
    const remove_zig_out = b.addRemoveDirTree(b.path("zig-out"));
    const remove_zig_cache = b.addRemoveDirTree(b.path(".zig-cache"));
    clean_step.dependOn(&remove_zig_out.step);
    clean_step.dependOn(&remove_zig_cache.step);

    // Development workflow: format, test, and build
    const dev_step = b.step("dev", "Development workflow: format, test, and build");
    dev_step.dependOn(&fmt.step);
    dev_step.dependOn(&run_unit_tests.step);
    dev_step.dependOn(b.getInstallStep());
}
