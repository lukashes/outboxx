const std = @import("std");
const testing = std.testing;
const test_helpers = @import("test_helpers");

const ProcessorModule = @import("cdc_processor");
const WalReader = @import("wal_reader").WalReader;
const PostgresPollingSource = @import("postgres_polling_source").PostgresPollingSource;
const Processor = ProcessorModule.Processor(PostgresPollingSource);
const config_module = @import("config");
const KafkaSink = config_module.KafkaSink;
const Stream = config_module.Stream;
const c = test_helpers.c;

// Helper to create and initialize processor for tests
fn createTestProcessor(
    allocator: std.mem.Allocator,
    wal_reader: *WalReader,
    stream_config: Stream,
    kafka_config: KafkaSink,
) !struct { processor: Processor, source: PostgresPollingSource } {
    const streams = try allocator.alloc(Stream, 1);
    streams[0] = stream_config;

    var source = PostgresPollingSource.init(allocator, wal_reader);

    var processor = Processor.init(allocator, source, streams, kafka_config);

    // Initialize Kafka connection
    processor.initialize() catch |err| {
        allocator.free(streams);
        source.deinit();
        return err;
    };

    return .{ .processor = processor, .source = source };
}

fn deinitTestProcessor(processor: *Processor, source: *PostgresPollingSource, allocator: std.mem.Allocator) void {
    allocator.free(processor.streams);
    processor.deinit();
    source.deinit();
}

// NOTE: Old integration tests that checked implementation details (last_sent_lsn,
// flushAndCommit(), shutdown()) have been removed. This functionality is now
// tested by E2E tests which verify the complete pipeline.

test "Processor: initialization" {
    const allocator = testing.allocator;

    const kafka_config = KafkaSink{
        .brokers = &[_][]const u8{"localhost:9092"},
    };

    const stream_config = try test_helpers.createTestStreamConfig(allocator, "test_table", "test_topic");
    defer allocator.free(stream_config.name);

    var wal_reader = WalReader.init(allocator, "test_slot", "test_pub", &[_][]const u8{});
    defer wal_reader.deinit();

    var source = PostgresPollingSource.init(allocator, &wal_reader);
    defer source.deinit();

    const streams = try allocator.alloc(Stream, 1);
    defer allocator.free(streams);
    streams[0] = stream_config;

    var processor = Processor.init(allocator, source, streams, kafka_config);
    defer processor.deinit();

    // Verify processor is initialized in correct state
    try testing.expect(processor.kafka_producer == null); // Not initialized until initialize() is called
    try testing.expect(processor.events_processed == 0);
}
