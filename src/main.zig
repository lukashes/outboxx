const std = @import("std");
const print = std.debug.print;
const Config = @import("config.zig").Config;
const KafkaWalReader = @import("wal/kafka_reader.zig").KafkaWalReader;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .retain_metadata = true,
    }){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("Memory leak detected!", .{});
            std.process.exit(1);
        } else {
            std.log.info("No memory leaks detected", .{});
        }
    }
    const allocator = gpa.allocator();

    print("Outboxx - PostgreSQL Change Data Capture with Kafka\n", .{});
    print("Version: 0.1.0-dev\n", .{});
    print("Build: Debug\n\n", .{});

    // Load default configuration
    const config = Config.default();
    print("Configuration loaded:\n", .{});
    print("  PostgreSQL: {s}:{}\n", .{ config.host, config.port });
    print("  Database: {s}\n", .{config.database});
    print("  User: {s}\n", .{config.user});
    print("  Slot: {s}\n", .{config.slot_name});
    print("  Kafka: localhost:9092\n\n", .{});

    // Initialize Kafka WAL reader
    var kafka_wal_reader = KafkaWalReader.init(allocator, config.slot_name, "localhost:9092");
    defer kafka_wal_reader.deinit();

    // Connect to PostgreSQL
    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    print("Connecting to PostgreSQL and Kafka...\n", .{});

    kafka_wal_reader.connect(conn_str) catch |err| {
        print("Failed to connect: {}\n", .{err});
        return;
    };

    // Clean up any existing slot (ignore errors)
    kafka_wal_reader.dropSlot() catch {};

    // Create replication slot
    kafka_wal_reader.createSlot() catch |err| {
        print("Failed to create replication slot: {}\n", .{err});
        return;
    };

    // Main CDC loop
    print("\n=== Starting CDC streaming: PostgreSQL → Kafka ===\n", .{});
    print("Listening for changes... (Press Ctrl+C to stop)\n\n", .{});

    var iteration: u32 = 0;
    while (iteration < 50) : (iteration += 1) {  // Limit iterations for testing
        print("--- Polling for changes (iteration {}) ---\n", .{iteration + 1});

        kafka_wal_reader.streamChangesToKafka(10) catch |err| {
            print("Error in streaming: {}\n", .{err});
            std.Thread.sleep(1000000000); // Sleep 1 second
            continue;
        };

        // Sleep for 3 seconds between polls
        std.Thread.sleep(3000000000);
    }

    // Clean up replication slot
    print("\nShutting down...\n", .{});
    kafka_wal_reader.dropSlot() catch {};
    print("CDC streaming stopped.\n", .{});
}
