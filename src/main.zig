const std = @import("std");
const print = std.debug.print;
const Config = @import("config").Config;
const Processor = @import("processor/processor.zig").Processor;
const PostgresValidator = @import("source/postgres/validator.zig").PostgresValidator;
const builtin = @import("builtin");
const posix = std.posix;

var shutdown_requested = std.atomic.Value(bool).init(false);

fn handleShutdownSignal(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
    std.log.info("Shutdown signal received, initiating graceful shutdown...", .{});
}

fn setupSignalHandlers() void {
    var act = posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);

    std.log.info("Signal handlers installed (SIGINT, SIGTERM)", .{});
}

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

pub fn main() void {
    const exit_code = run() catch |err| {
        std.log.err("Fatal error: {}", .{err});
        std.process.exit(1);
    };
    std.process.exit(exit_code);
}

fn run() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .retain_metadata = true,
    }){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("Memory leak detected!", .{});
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
            return 1;
        };
    } else {
        print("ERROR: Config file is required. Use --config <path>\n", .{});
        return 1;
    };
    defer config.deinit(allocator);

    // Validate configuration - fail fast if invalid
    config.validate(allocator) catch |err| {
        print("ERROR: Configuration validation failed: {}\n", .{err});
        print("Please check your configuration file and ensure all required fields are present.\n", .{});
        return 1;
    };

    // Load passwords from environment variables
    config.loadPasswords(allocator) catch |err| {
        print("ERROR: Failed to load passwords from environment: {}\n", .{err});
        return 1;
    };

    const postgres = config.source.postgres.?;
    print("Configuration loaded:\n", .{});
    print("  PostgreSQL: {s}:{}\n", .{ postgres.host, postgres.port });
    print("  Database: {s}\n", .{postgres.database});
    print("  User: {s}\n", .{postgres.user});
    print("  Slot: {s}\n", .{postgres.slot_name});

    // Validate PostgreSQL connection and settings
    const conn_str = try config.postgresConnectionString(allocator);
    defer allocator.free(conn_str);

    print("\nValidating PostgreSQL connection and settings...\n", .{});

    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    validator.connect(conn_str) catch |err| {
        print("ERROR: PostgreSQL connection failed: {}\n", .{err});
        return 1;
    };

    validator.checkPostgresVersion() catch |err| {
        print("ERROR: PostgreSQL version check failed: {}\n", .{err});
        return 1;
    };

    validator.checkWalLevel() catch |err| {
        print("ERROR: PostgreSQL wal_level check failed: {}\n", .{err});
        return 1;
    };

    // Validate all tables from streams exist
    for (config.streams) |stream| {
        validator.checkTableExists("public", stream.source.resource) catch |err| {
            print("ERROR: Table validation failed for '{s}': {}\n", .{ stream.source.resource, err });
            return 1;
        };
    }

    print("PostgreSQL validation completed successfully!\n", .{});

    // Setup signal handlers for graceful shutdown
    setupSignalHandlers();

    // Connect to PostgreSQL
    print("\nStarting CDC processor...\n", .{});
    print("Connecting to PostgreSQL...\n", .{});

    // Check if any streams are configured
    if (config.streams.len == 0) {
        print("Error: No streams configured in config file\n", .{});
        return 1;
    }

    print("\nStarting processor for {} stream(s)...\n", .{config.streams.len});

    // Collect all unique tables from streams
    var tables_list = std.ArrayList([]const u8).empty;
    defer tables_list.deinit(allocator);

    for (config.streams) |stream| {
        // Check if table already in list
        var found = false;
        for (tables_list.items) |table| {
            if (std.mem.eql(u8, table, stream.source.resource)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try tables_list.append(allocator, stream.source.resource);
        }
    }

    // Create single WalReader for all streams
    const WalReader = @import("wal_reader").WalReader;
    var wal_reader = WalReader.init(
        allocator,
        postgres.slot_name,
        postgres.publication_name,
        tables_list.items, // Pass monitored tables for fast filtering (test_decoding optimization)
    );
    defer wal_reader.deinit();

    // Initialize WalReader with all tables
    print("Initializing WAL reader with {} table(s)...\n", .{tables_list.items.len});
    for (tables_list.items) |table| {
        print("  - {s}\n", .{table});
    }

    wal_reader.initialize(conn_str, tables_list.items) catch |err| {
        std.log.err("Failed to initialize WAL reader: {}", .{err});
        return 1;
    };

    // Create single Processor for all streams
    var processor = Processor.init(allocator, &wal_reader, config.streams, config.sink.kafka.?);
    defer processor.deinit();

    // Initialize Processor (Kafka connection)
    processor.initialize() catch |err| {
        std.log.err("Failed to initialize processor: {}", .{err});
        return 1;
    };

    print("\nProcessor initialized successfully with slot: {s}\n", .{postgres.slot_name});

    print("\nCDC processor started successfully!\n", .{});
    print("Monitoring WAL changes from {} stream(s)\n", .{config.streams.len});
    for (config.streams) |stream| {
        print("  - {s} -> {s}\n", .{ stream.source.resource, stream.sink.destination });
    }
    print("Using publication: {s}\n", .{postgres.publication_name});
    print("Press Ctrl+C to stop gracefully.\n\n", .{});

    // Start streaming loop
    while (!shutdown_requested.load(.seq_cst)) {
        processor.processChangesToKafka(100) catch |err| {
            std.log.warn("Error processing WAL changes: {}", .{err});
            std.Thread.sleep(1 * std.time.ns_per_s);
            continue;
        };

        // Short sleep between batches
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    if (shutdown_requested.load(.seq_cst)) {
        print("\nGraceful shutdown initiated...\n", .{});
        processor.shutdown();
        print("Graceful shutdown completed successfully\n", .{});
        return 0;
    }

    return 1;
}
