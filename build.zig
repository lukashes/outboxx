const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allow the person running zig build to pick the architecture and OS
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running zig build to pick the optimization level
    const optimize = b.standardOptimizeOption(.{});

    // Add TOML dependency, sadly it was not working with 0.15.1 zig version
    // TODO: Check it later again
    const toml_dep = b.dependency("toml", .{});
    const toml_module = toml_dep.module("toml");

    // Domain module (new architecture) - must be defined before use
    const domain_module = b.createModule(.{
        .root_source_file = b.path("src/domain/change_event.zig"),
        .target = target,
        .optimize = optimize,
    });

    // JSON serialization module (new architecture)
    const json_serialization_module = b.createModule(.{
        .root_source_file = b.path("src/serialization/json.zig"),
        .target = target,
        .optimize = optimize,
    });
    json_serialization_module.addImport("domain", domain_module);

    // PostgreSQL WAL parser module (new architecture)
    const postgres_wal_parser_module = b.createModule(.{
        .root_source_file = b.path("src/source/postgres/wal_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    postgres_wal_parser_module.addImport("domain", domain_module);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "outboxx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Dependencies for the main executable
    exe.root_module.addImport("toml", toml_module);
    exe.root_module.addImport("domain", domain_module);
    exe.root_module.addImport("json_serialization", json_serialization_module);
    exe.root_module.addImport("postgres_wal_parser", postgres_wal_parser_module);

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

    // Config tests - now in config directory
    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config/config_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    config_tests.root_module.addImport("toml", toml_module);

    const wal_reader_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/wal_reader_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wal_reader_tests.linkLibC();
    wal_reader_tests.linkSystemLibrary("pq");


    // Domain layer tests (new)
    const domain_tests = b.addTest(.{
        .root_module = domain_module,
    });

    // JSON serialization tests (new)
    const json_serialization_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/serialization/json.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    json_serialization_tests.root_module.addImport("domain", domain_module);

    // PostgreSQL WAL parser tests (new)
    const postgres_wal_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/wal_parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    postgres_wal_parser_tests.root_module.addImport("domain", domain_module);

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

    const run_config_tests = b.addRunArtifact(config_tests);
    const run_wal_reader_tests = b.addRunArtifact(wal_reader_tests);
    const run_domain_tests = b.addRunArtifact(domain_tests);
    const run_json_serialization_tests = b.addRunArtifact(json_serialization_tests);
    const run_postgres_wal_parser_tests = b.addRunArtifact(postgres_wal_parser_tests);
    const run_kafka_producer_tests = b.addRunArtifact(kafka_producer_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_wal_reader_tests.step);
    test_step.dependOn(&run_domain_tests.step);
    test_step.dependOn(&run_json_serialization_tests.step);
    test_step.dependOn(&run_postgres_wal_parser_tests.step);
    test_step.dependOn(&run_kafka_producer_tests.step);

    // Integration tests (moved to src/ for simplicity)
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.root_module.addImport("domain", domain_module);
    integration_tests.root_module.addImport("json_serialization", json_serialization_module);
    integration_tests.root_module.addImport("postgres_wal_parser", postgres_wal_parser_module);
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
    dev_step.dependOn(&run_config_tests.step);
    dev_step.dependOn(b.getInstallStep());
}
