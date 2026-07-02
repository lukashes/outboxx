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

    // Constants module (application-wide constants)
    const constants_module = b.createModule(.{
        .root_source_file = b.path("src/constants.zig"),
        .target = target,
        .optimize = optimize,
    });

    // TOML parser dependency (parses config straight into Zig structs)
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const toml_module = toml_dep.module("toml");

    // Config module (for type definitions like KafkaSink, Stream, etc.)
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_module.addImport("toml", toml_module);

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
    postgres_source_module.addImport("constants", constants_module);

    // C bindings via build-system translate-c, split by deployment target so the
    // test-only mock cluster API never reaches the production binary. Each target
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

    postgres_source_module.addImport("c", c_prod_module);

    // Kafka producer module
    const kafka_producer_module = b.createModule(.{
        .root_source_file = b.path("src/kafka/producer.zig"),
        .target = target,
        .optimize = optimize,
    });
    kafka_producer_module.addImport("constants", constants_module);
    kafka_producer_module.addImport("c", c_prod_module);

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
    cdc_processor_module.addImport("constants", constants_module);

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
    exe.root_module.addImport("domain", domain_module);
    exe.root_module.addImport("json_serialization", json_serialization_module);
    exe.root_module.addImport("kafka_producer", kafka_producer_module);
    exe.root_module.addImport("config", config_module);
    exe.root_module.addImport("postgres_source", postgres_source_module);
    exe.root_module.addImport("constants", constants_module);
    exe.root_module.addImport("c", c_prod_module);

    // Link libc for PostgreSQL and Kafka C libraries
    exe.root_module.link_libc = true;

    // Add PostgreSQL library (libpq)
    exe.root_module.linkSystemLibrary("pq", .{});

    // Add Kafka library (librdkafka)
    exe.root_module.linkSystemLibrary("rdkafka", .{});

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
    kafka_producer_tests.root_module.addImport("constants", constants_module);
    kafka_producer_tests.root_module.addImport("c", c_dev_module);
    kafka_producer_tests.root_module.link_libc = true;
    kafka_producer_tests.root_module.linkSystemLibrary("rdkafka", .{});

    // ReplicationProtocol tests
    const replication_protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/replication_protocol_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    replication_protocol_tests.root_module.addImport("c", c_dev_module);
    replication_protocol_tests.root_module.link_libc = true;
    replication_protocol_tests.root_module.linkSystemLibrary("pq", .{});

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
    streaming_source_tests.root_module.addImport("constants", constants_module);
    streaming_source_tests.root_module.addImport("c", c_dev_module);
    streaming_source_tests.root_module.link_libc = true;
    streaming_source_tests.root_module.linkSystemLibrary("pq", .{});

    // Streaming replication integration tests
    const streaming_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    streaming_integration_tests.root_module.addImport("domain", domain_module);
    streaming_integration_tests.root_module.addImport("constants", constants_module);
    streaming_integration_tests.root_module.addImport("c", c_dev_module);
    streaming_integration_tests.root_module.link_libc = true;
    streaming_integration_tests.root_module.linkSystemLibrary("pq", .{});

    // Validator tests
    const validator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/source/postgres/validator_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    validator_tests.root_module.addImport("c", c_dev_module);
    validator_tests.root_module.link_libc = true;
    validator_tests.root_module.linkSystemLibrary("pq", .{});

    // Test helpers module (shared utilities for all tests)
    const test_helpers_module = b.createModule(.{
        .root_source_file = b.path("tests/test_helpers.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_helpers_module.addImport("config", config_module);
    test_helpers_module.addImport("c", c_dev_module);
    test_helpers_module.link_libc = true;

    // Add test_helpers to integration tests
    replication_protocol_tests.root_module.addImport("test_helpers", test_helpers_module);
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
    test_step.dependOn(&run_pg_output_decoder_tests.step);
    test_step.dependOn(&run_relation_registry_tests.step);
    test_step.dependOn(&run_streaming_source_tests.step);

    // E2E Tests - Full cycle: PostgreSQL → CDC → Kafka
    // These tests validate the complete data pipeline

    // E2E: CDC operations test (INSERT, UPDATE, DELETE)
    const e2e_streaming_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e/cdc_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    e2e_streaming_test.root_module.addImport("test_helpers", test_helpers_module);
    e2e_streaming_test.root_module.addImport("cdc_processor", cdc_processor_module);
    e2e_streaming_test.root_module.addImport("config", config_module);
    e2e_streaming_test.root_module.addImport("postgres_source", postgres_source_module);
    e2e_streaming_test.root_module.link_libc = true;
    e2e_streaming_test.root_module.linkSystemLibrary("pq", .{});
    e2e_streaming_test.root_module.linkSystemLibrary("rdkafka", .{});

    const run_e2e_streaming_test = b.addRunArtifact(e2e_streaming_test);

    // Kafka integration tests (in kafka directory)
    const kafka_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kafka/producer_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kafka_integration_tests.root_module.addImport("constants", constants_module);
    kafka_integration_tests.root_module.addImport("c", c_dev_module);
    kafka_integration_tests.root_module.link_libc = true;
    kafka_integration_tests.root_module.linkSystemLibrary("rdkafka", .{});

    const run_kafka_integration_tests = b.addRunArtifact(kafka_integration_tests);
    const run_streaming_integration_tests = b.addRunArtifact(streaming_integration_tests);

    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_kafka_producer_tests.step);
    integration_test_step.dependOn(&run_kafka_integration_tests.step);
    integration_test_step.dependOn(&run_streaming_integration_tests.step);
    integration_test_step.dependOn(&run_replication_protocol_tests.step);
    integration_test_step.dependOn(&run_validator_tests.step);

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
    debug_exe.root_module.link_libc = true;
    debug_exe.root_module.linkSystemLibrary("pq", .{});

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
    release_small_exe.root_module.link_libc = true;
    release_small_exe.root_module.linkSystemLibrary("pq", .{});

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

    // Clean build artifacts. No std build step for a recursive delete, so shell out.
    const clean_step = b.step("clean", "Clean build artifacts");
    const remove_artifacts = b.addSystemCommand(&.{ "rm", "-rf", "zig-out", ".zig-cache" });
    clean_step.dependOn(&remove_artifacts.step);

    // Development workflow: format, test, and build
    const dev_step = b.step("dev", "Development workflow: format, test, and build");
    dev_step.dependOn(&fmt.step);
    dev_step.dependOn(&run_config_tests.step);
    dev_step.dependOn(b.getInstallStep());

    // Benchmarks with zbench
    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const zbench_module = zbench_dep.module("zbench");

    const pg_output_decoder_module = b.createModule(.{
        .root_source_file = b.path("src/source/postgres/pg_output_decoder.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const bench_helpers_module = b.createModule(.{
        .root_source_file = b.path("tests/benchmarks/bench_helpers.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const serializer_bench = b.addTest(.{
        .name = "serializer_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmarks/components/serializer_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    serializer_bench.root_module.addImport("zbench", zbench_module);
    serializer_bench.root_module.addImport("domain", domain_module);
    serializer_bench.root_module.addImport("json_serialization", json_serialization_module);
    serializer_bench.root_module.addImport("bench_helpers", bench_helpers_module);

    const install_serializer_bench = b.addInstallArtifact(serializer_bench, .{});

    const decoder_bench = b.addTest(.{
        .name = "decoder_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmarks/components/decoder_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    decoder_bench.root_module.addImport("zbench", zbench_module);
    decoder_bench.root_module.addImport("pg_output_decoder", pg_output_decoder_module);
    decoder_bench.root_module.addImport("bench_helpers", bench_helpers_module);

    const install_decoder_bench = b.addInstallArtifact(decoder_bench, .{});

    const match_streams_bench = b.addTest(.{
        .name = "match_streams_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmarks/components/match_streams_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    match_streams_bench.root_module.addImport("zbench", zbench_module);
    match_streams_bench.root_module.addImport("config", config_module);
    match_streams_bench.root_module.addImport("bench_helpers", bench_helpers_module);
    match_streams_bench.root_module.addImport("processor", cdc_processor_module);

    const install_match_streams_bench = b.addInstallArtifact(match_streams_bench, .{});

    const partition_key_bench = b.addTest(.{
        .name = "partition_key_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmarks/components/partition_key_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    partition_key_bench.root_module.addImport("zbench", zbench_module);
    partition_key_bench.root_module.addImport("domain", domain_module);
    partition_key_bench.root_module.addImport("bench_helpers", bench_helpers_module);

    const install_partition_key_bench = b.addInstallArtifact(partition_key_bench, .{});

    const kafka_bench = b.addTest(.{
        .name = "kafka_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmarks/components/kafka_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    kafka_bench.root_module.addImport("zbench", zbench_module);
    kafka_bench.root_module.addImport("kafka_producer", kafka_producer_module);
    kafka_bench.root_module.addImport("bench_helpers", bench_helpers_module);
    kafka_bench.root_module.addImport("c", c_dev_module);
    kafka_bench.root_module.link_libc = true;
    kafka_bench.root_module.linkSystemLibrary("rdkafka", .{});

    const install_kafka_bench = b.addInstallArtifact(kafka_bench, .{});

    const message_processor_bench = b.addTest(.{
        .name = "message_processor_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/benchmarks/components/message_processor_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    message_processor_bench.root_module.addImport("zbench", zbench_module);
    message_processor_bench.root_module.addImport("postgres_source", postgres_source_module);
    message_processor_bench.root_module.addImport("domain", domain_module);
    message_processor_bench.root_module.addImport("bench_helpers", bench_helpers_module);

    const install_message_processor_bench = b.addInstallArtifact(message_processor_bench, .{});

    const bench_step = b.step("bench", "Compile component benchmarks");
    bench_step.dependOn(&install_serializer_bench.step);
    bench_step.dependOn(&install_decoder_bench.step);
    bench_step.dependOn(&install_match_streams_bench.step);
    bench_step.dependOn(&install_partition_key_bench.step);
    bench_step.dependOn(&install_kafka_bench.step);
    bench_step.dependOn(&install_message_processor_bench.step);
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
