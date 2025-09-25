const std = @import("std");
const print = std.debug.print;
const Config = @import("config.zig").Config;
const CdcProcessor = @import("processor/cdc_processor.zig").CdcProcessor;

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
    print("  Kafka: {s}\n", .{config.kafka.brokers});
    print("  Flush timeout: {}ms\n", .{config.kafka.flush_timeout_ms});
    print("  Poll interval: {}ms\n\n", .{config.kafka.poll_interval_ms});

    // Initialize CDC processor
    var cdc_processor = CdcProcessor.init(allocator, config.slot_name, config.kafka);
    defer cdc_processor.deinit();

    // Connect to PostgreSQL
    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    print("Connecting to PostgreSQL and Kafka...\n", .{});

    cdc_processor.connect(conn_str) catch |err| {
        print("Failed to connect: {}\n", .{err});
        return;
    };

    // Clean up any existing slot (ignore errors)
    cdc_processor.dropSlot() catch {};

    // Create replication slot
    cdc_processor.createSlot() catch |err| {
        print("Failed to create replication slot: {}\n", .{err});
        return;
    };

    // Main CDC loop
    print("\n=== Starting CDC streaming: PostgreSQL -> Kafka ===\n", .{});
    print("Listening for changes... (Press Ctrl+C to stop)\n\n", .{});

    var iteration: u32 = 0;
    while (iteration < 50) : (iteration += 1) { // Limit iterations for testing
        print("--- Polling for changes (iteration {}) ---\n", .{iteration + 1});

        cdc_processor.processChangesToKafka(10) catch |err| {
            print("Error in streaming: {}\n", .{err});
            std.Thread.sleep(1000000000); // Sleep 1 second
            continue;
        };

        // Sleep between polls using configuration
        std.Thread.sleep(config.kafka.poll_interval_ms * std.time.ns_per_ms);
    }

    // Clean up replication slot
    print("\nShutting down...\n", .{});
    cdc_processor.dropSlot() catch {};
    print("CDC streaming stopped.\n", .{});
}
