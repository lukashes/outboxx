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

    // Config module (for type definitions like KafkaSink, Stream, etc.)
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config/config.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // PostgreSQL source module (adapter)
    const postgres_source_module = b.createModule(.{
        .root_source_file = b.path("src/source/postgres/source.zig"),
        .target = target,
        .optimize = optimize,
    });
    postgres_source_module.addImport("domain", domain_module);

    // Kafka producer module
    const kafka_producer_module = b.createModule(.{
        .root_source_file = b.path("src/kafka/producer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Processor module with all dependencies
    const cdc_processor_module = b.createModule(.{
        .root_source_file = b.path("src/processor/processor.zig"),
        .target = target,
        .optimize = optimize,
    });
    cdc_processor_module.addImport("domain", domain_module);
    cdc_processor_module.addImport("postgres_source", postgres_source_module);
    cdc_processor_module.addImport("json_serialization", json_serialization_module);
    cdc_processor_module.addImport("kafka_producer", kafka_producer_module);
    cdc_processor_module.addImport("config", config_module);

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

    // Dependencies for the main executable
    exe.root_module.addImport("toml", toml_module);
    exe.root_module.addImport("domain", domain_module);
    exe.root_module.addImport("json_serialization", json_serialization_module);
    exe.root_module.addImport("kafka_producer", kafka_producer_module);
    exe.root_module.addImport("config", config_module);
    exe.root_module.addImport("postgres_source", postgres_source_module);

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

    // ReplicationProtocol tests
    const replication_protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/replication_protocol_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    replication_protocol_tests.linkLibC();
    replication_protocol_tests.linkSystemLibrary("pq");

    // PgOutputDecoder tests
    const pg_output_decoder_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/pg_output_decoder_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // RelationRegistry tests
    const relation_registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/relation_registry_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // PostgresStreamingSource tests
    const streaming_source_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/source_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    streaming_source_tests.root_module.addImport("domain", domain_module);
    streaming_source_tests.linkLibC();
    streaming_source_tests.linkSystemLibrary("pq");

    // Streaming replication integration tests
    const streaming_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    streaming_integration_tests.root_module.addImport("domain", domain_module);
    streaming_integration_tests.linkLibC();
    streaming_integration_tests.linkSystemLibrary("pq");

    // Validator tests
    const validator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/validator_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    validator_tests.linkLibC();
    validator_tests.linkSystemLibrary("pq");

    // Test helpers module (shared utilities for all tests)
    const test_helpers_module = b.createModule(.{
        .root_source_file = b.path("tests/test_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_helpers_module.addImport("config", config_module);

    // Add test_helpers to replication_protocol_tests
    replication_protocol_tests.root_module.addImport("test_helpers", test_helpers_module);

    // Add test_helpers to streaming_integration_tests
    streaming_integration_tests.root_module.addImport("test_helpers", test_helpers_module);

    const run_config_tests = b.addRunArtifact(config_tests);
    const run_domain_tests = b.addRunArtifact(domain_tests);
    const run_json_serialization_tests = b.addRunArtifact(json_serialization_tests);
    const run_kafka_producer_tests = b.addRunArtifact(kafka_producer_tests);
    const run_replication_protocol_tests = b.addRunArtifact(replication_protocol_tests);
    const run_pg_output_decoder_tests = b.addRunArtifact(pg_output_decoder_tests);
    const run_relation_registry_tests = b.addRunArtifact(relation_registry_tests);
    const run_streaming_source_tests = b.addRunArtifact(streaming_source_tests);
    const run_validator_tests = b.addRunArtifact(validator_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_domain_tests.step);
    test_step.dependOn(&run_json_serialization_tests.step);
    test_step.dependOn(&run_kafka_producer_tests.step);
    test_step.dependOn(&run_replication_protocol_tests.step);
    test_step.dependOn(&run_pg_output_decoder_tests.step);
    test_step.dependOn(&run_relation_registry_tests.step);
    test_step.dependOn(&run_streaming_source_tests.step);
    test_step.dependOn(&run_validator_tests.step);

    // E2E Tests - Full cycle: PostgreSQL → CDC → Kafka
    // These tests validate the complete data pipeline

    // E2E: Streaming CDC operations test (INSERT, UPDATE, DELETE) using PostgresStreamingSource
    const e2e_streaming_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/streaming_cdc_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    e2e_streaming_test.root_module.addImport("test_helpers", test_helpers_module);
    e2e_streaming_test.root_module.addImport("cdc_processor", cdc_processor_module);
    e2e_streaming_test.root_module.addImport("config", config_module);
    e2e_streaming_test.root_module.addImport("postgres_source", postgres_source_module);
    e2e_streaming_test.linkLibC();
    e2e_streaming_test.linkSystemLibrary("pq");
    e2e_streaming_test.linkSystemLibrary("rdkafka");

    const run_e2e_streaming_test = b.addRunArtifact(e2e_streaming_test);

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

    const run_kafka_integration_tests = b.addRunArtifact(kafka_integration_tests);
    const run_streaming_integration_tests = b.addRunArtifact(streaming_integration_tests);

    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_kafka_integration_tests.step);
    integration_test_step.dependOn(&run_streaming_integration_tests.step);

    // E2E test step - Full pipeline tests (PostgreSQL → CDC → Kafka)
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
