const std = @import("std");
const print = std.debug.print;
const Config = @import("config/config.zig").Config;
const WalReader = @import("wal/reader.zig").WalReader;
const CdcProcessor = @import("processor/cdc_processor.zig").CdcProcessor;

/// Sanitize stream name for PostgreSQL publication name
/// Replaces invalid characters with underscores
fn sanitizeStreamName(allocator: std.mem.Allocator, stream_name: []const u8) ![]u8 {
    const sanitized = try allocator.alloc(u8, stream_name.len);
    for (stream_name, 0..) |char, i| {
        sanitized[i] = switch (char) {
            '-', ' ', '.', '/', '\\' => '_',
            else => char,
        };
    }
    return sanitized;
}

/// Generate publication name from stream name
/// Format: "outboxx_{sanitized_stream_name}_pub"
fn generatePublicationName(allocator: std.mem.Allocator, stream_name: []const u8) ![]u8 {
    const sanitized = try sanitizeStreamName(allocator, stream_name);
    defer allocator.free(sanitized);

    return std.fmt.allocPrint(allocator, "outboxx_{s}_pub", .{sanitized});
}

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

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config_file_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
            config_file_path = args[i + 1];
            i += 1; // Skip the config file path argument
        }
    }

    // Load configuration from TOML file - fail fast approach
    var config = if (config_file_path) |path| blk: {
        print("Loading configuration from: {s}\n", .{path});
        break :blk Config.loadFromTomlFile(allocator, path) catch |err| {
            print("ERROR: Failed to load config from {s}: {}\n", .{ path, err });
            std.process.exit(1);
        };
    } else {
        print("ERROR: Config file is required. Use --config <path>\n", .{});
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // Validate configuration - fail fast if invalid
    config.validate(allocator) catch |err| {
        print("ERROR: Configuration validation failed: {}\n", .{err});
        print("Please check your configuration file and ensure all required fields are present.\n", .{});
        std.process.exit(1);
    };

    // Load passwords from environment variables
    config.loadPasswords(allocator) catch |err| {
        print("ERROR: Failed to load passwords from environment: {}\n", .{err});
        std.process.exit(1);
    };

    const postgres = config.source.postgres.?;
    print("Configuration loaded:\n", .{});
    print("  PostgreSQL: {s}:{}\n", .{ postgres.host, postgres.port });
    print("  Database: {s}\n", .{postgres.database});
    print("  User: {s}\n", .{postgres.user});
    print("  Slot: {s}\n", .{postgres.slot_name});

    // Connect to PostgreSQL and validate connection
    const conn_str = try config.postgresConnectionString(allocator);
    defer allocator.free(conn_str);

    print("Connection string: {s}\n", .{conn_str});
    print("Configuration validated successfully!\n", .{});

    // Connect to PostgreSQL
    print("\nStarting CDC processor...\n", .{});
    print("Connecting to PostgreSQL...\n", .{});

    // Check if any streams are configured
    if (config.streams.len == 0) {
        print("Error: No streams configured in config file\n", .{});
        return;
    }

    print("\nStarting CDC processors for {} stream(s)...\n", .{config.streams.len});

    // Create array of CDC processors - one for each stream
    const processors = try allocator.alloc(CdcProcessor, config.streams.len);
    defer allocator.free(processors);

    // Create array to store slot names (must persist for the lifetime of processors)
    const slot_names = try allocator.alloc([]u8, config.streams.len);
    defer {
        for (slot_names) |slot_name| {
            allocator.free(slot_name);
        }
        allocator.free(slot_names);
    }

    // Create array to store publication names (must persist for the lifetime of processors)
    const publication_names = try allocator.alloc([]u8, config.streams.len);
    defer {
        for (publication_names) |publication_name| {
            allocator.free(publication_name);
        }
        allocator.free(publication_names);
    }

    // Track successfully initialized processors
    var initialized_count: usize = 0;

    // Initialize all processors with error handling
    for (config.streams, 0..) |stream_config, stream_index| {
        // Each stream gets its own slot to avoid conflicts
        slot_names[stream_index] = try std.fmt.allocPrint(allocator, "{s}_stream_{d}", .{ postgres.slot_name, stream_index });

        // Generate unique publication name for this stream
        publication_names[stream_index] = try generatePublicationName(allocator, stream_config.name);

        processors[stream_index] = CdcProcessor.init(allocator, slot_names[stream_index], publication_names[stream_index], config.sink.kafka.?, stream_config);

        print("Initializing processor for stream '{s}' -> topic '{s}' (publication: {s})\n", .{ stream_config.name, stream_config.sink.destination, publication_names[stream_index] });

        processors[stream_index].initialize(conn_str) catch |err| {
            std.log.err("Failed to initialize stream '{s}': {}", .{ stream_config.name, err });
            processors[stream_index].deinit(); // Clean up failed processor
            continue;
        };

        print("Stream '{s}' initialized with slot: {s}\n", .{ stream_config.name, slot_names[stream_index] });
        initialized_count += 1;
    }

    // Check if any processors were successfully initialized
    if (initialized_count == 0) {
        print("Error: No streams were successfully initialized\n", .{});
        return;
    } else if (initialized_count < config.streams.len) {
        print("Warning: Only {}/{} streams were successfully initialized\n", .{ initialized_count, config.streams.len });
    }

    // Cleanup function for all processors
    defer {
        for (processors) |*processor| {
            processor.deinit();
        }
    }

    print("\nCDC processors started successfully!\n", .{});
    print("Monitoring WAL changes from {}/{} stream(s)\n", .{ initialized_count, config.streams.len });
    print("Using publication: {s}\n", .{postgres.publication_name});
    print("Press Ctrl+C to stop gracefully.\n\n", .{});

    // Start streaming in a round-robin fashion for all processors
    var current_processor: usize = 0;
    var failed_attempts: usize = 0;
    const max_failed_attempts = initialized_count * 5; // Allow 5 cycles of failures before giving up

    while (true) {
        // Skip processors that failed to initialize
        // Find next initialized processor
        var attempts: usize = 0;
        while (attempts < config.streams.len) {
            if (current_processor < config.streams.len) {
                // Check if this processor was successfully initialized by trying a dummy operation
                var processor_valid = true;

                // Try to process changes for current processor
                processors[current_processor].processChangesToKafka(100) catch |err| {
                    std.log.err("Error in stream '{}' ({s}): {}", .{ current_processor, config.streams[current_processor].name, err });
                    processor_valid = false;
                    failed_attempts += 1;
                };

                if (processor_valid) {
                    failed_attempts = 0; // Reset failure counter on success
                    break;
                }
            }

            // Move to next processor
            current_processor = (current_processor + 1) % config.streams.len;
            attempts += 1;
        }

        // If all processors have failed too many times, exit
        if (failed_attempts >= max_failed_attempts) {
            std.log.err("All processors have failed too many times. Shutting down.", .{});
            break;
        }

        // Move to next processor (round-robin)
        current_processor = (current_processor + 1) % config.streams.len;

        // Short sleep between processor switches
        std.Thread.sleep(100 * std.time.ns_per_ms); // 100ms

        // Longer sleep after full round
        if (current_processor == 0) {
            std.Thread.sleep(1 * std.time.ns_per_s); // 1 second
        }
    }
}
