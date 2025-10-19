const std = @import("std");
const config_mod = @import("config");
const Config = config_mod.Config;
const Stream = config_mod.Stream;
const ProcessorModule = @import("processor/processor.zig");
const PostgresValidator = @import("source/postgres_polling/validator.zig").PostgresValidator;
const PostgresPollingSource = @import("postgres_polling_source").PostgresPollingSource;
const PostgresStreamingSource = @import("source/postgres_streaming/source.zig").PostgresStreamingSource;
const builtin = @import("builtin");
const posix = std.posix;
const constants = @import("constants.zig");

pub const CliError = error{
    NoConfigPath,
};

var shutdown_requested = std.atomic.Value(bool).init(false);

pub fn main() void {
    run() catch |err| {
        std.log.err("Fatal error: {}", .{err});
        std.process.exit(1);
    };
    std.process.exit(0);
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .retain_metadata = true,
    }){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("Memory leak detected!", .{});
        } else {
            std.log.debug("No memory leaks detected", .{});
        }
    }
    const allocator = gpa.allocator();

    printBanner();

    const config_file_path = try parseConfigPath(allocator) orelse {
        std.log.warn("config file is required. Use --config <path>", .{});
        return CliError.NoConfigPath;
    };
    defer allocator.free(config_file_path);

    printStatus("Loading configuration from: {s}\n", .{config_file_path});
    var config = try Config.loadFromTomlFile(allocator, config_file_path);
    defer config.deinit(allocator);

    try config.validate(allocator);
    try config.loadPasswords(allocator);

    printConfigInfo(config);

    try validatePostgres(allocator, config);

    const postgres = config.source.postgres.?;

    setupSignalHandlers();

    printStatus("\nStarting CDC processor...\n", .{});
    printStatus("\nStarting processor for {} stream(s)...\n", .{config.streams.len});

    const tables = try collectUniqueTables(allocator, config.streams);
    defer allocator.free(tables);

    const conn_str = try config.postgresConnectionString(allocator);
    defer allocator.free(conn_str);

    // Create source and processor based on engine configuration
    switch (postgres.engine) {
        .polling => {
            printStatus("Using PostgreSQL polling source (test_decoding)\n", .{});

            const WalReader = @import("wal_reader").WalReader;
            var wal_reader = WalReader.init(
                allocator,
                postgres.slot_name,
                postgres.publication_name,
                tables,
            );
            defer wal_reader.deinit();

            printStatus("Initializing WAL reader with {} table(s)...\n", .{tables.len});
            for (tables) |table| {
                printStatus("  - {s}\n", .{table});
            }

            try wal_reader.initialize(conn_str, tables);

            var source = PostgresPollingSource.init(allocator, &wal_reader);
            defer source.deinit();

            const ProcessorType = ProcessorModule.Processor(PostgresPollingSource);
            var processor = ProcessorType.init(allocator, source, config.streams, config.sink.kafka.?);
            defer processor.deinit();

            try processor.initialize();

            printStatus("\nProcessor initialized successfully with slot: {s}\n", .{postgres.slot_name});
            printStatus("\nCDC processor started successfully!\n", .{});
            printStatus("Monitoring WAL changes from {} stream(s)\n", .{config.streams.len});
            for (config.streams) |stream| {
                printStatus("  - {s} -> {s}\n", .{ stream.source.resource, stream.sink.destination });
            }
            printStatus("Using publication: {s}\n", .{postgres.publication_name});
            printStatus("Press Ctrl+C to stop gracefully.\n\n", .{});

            try processor.startStreaming(&shutdown_requested);
        },
        .streaming => {
            printStatus("Using PostgreSQL streaming source (pgoutput)\n", .{});

            var source = PostgresStreamingSource.init(allocator, postgres.slot_name, postgres.publication_name);
            defer source.deinit();

            printStatus("Connecting to PostgreSQL streaming replication...\n", .{});
            try source.connect(conn_str, "0/0");

            const ProcessorType = ProcessorModule.Processor(PostgresStreamingSource);
            var processor = ProcessorType.init(allocator, source, config.streams, config.sink.kafka.?);
            defer processor.deinit();

            try processor.initialize();

            printStatus("\nProcessor initialized successfully with slot: {s}\n", .{postgres.slot_name});
            printStatus("\nCDC processor started successfully!\n", .{});
            printStatus("Monitoring WAL changes from {} stream(s)\n", .{config.streams.len});
            for (config.streams) |stream| {
                printStatus("  - {s} -> {s}\n", .{ stream.source.resource, stream.sink.destination });
            }
            printStatus("Using publication: {s}\n", .{postgres.publication_name});
            printStatus("Press Ctrl+C to stop gracefully.\n\n", .{});

            try processor.startStreaming(&shutdown_requested);
        },
    }
}

/// Print user-facing messages to stdout
/// Use this for status messages, configuration info, and other user output
/// For logs and diagnostics, use std.log.* (writes to stderr)
fn printStatus(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, fmt, args) catch |err| {
        std.log.warn("Failed to format message: {}", .{err});
        return;
    };
    const stdout_file = std.fs.File.stdout();
    stdout_file.writeAll(formatted) catch |err| {
        std.log.warn("Failed to write to stdout: {}", .{err});
    };
}

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

/// Collect unique table names from stream configurations
/// Uses StringHashMap for O(1) lookup instead of O(n²) linear search
fn collectUniqueTables(allocator: std.mem.Allocator, streams: []const Stream) ![]const []const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    for (streams) |stream| {
        const result = try seen.getOrPut(stream.source.resource);
        if (!result.found_existing) {
            try list.append(allocator, stream.source.resource);
        }
    }

    return list.toOwnedSlice(allocator);
}

fn printBanner() void {
    printStatus("{s} - {s}\n", .{ constants.APP_NAME, constants.DESCRIPTION });
    printStatus("Version: {s}\n", .{constants.VERSION});
    printStatus("Build: {s}\n\n", .{@tagName(constants.BUILD_MODE)});
}

fn parseConfigPath(allocator: std.mem.Allocator) !?[]const u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config") and i + 1 < args.len) {
            return try allocator.dupe(u8, args[i + 1]);
        }
    }

    return null;
}

fn printConfigInfo(cfg: Config) void {
    const postgres = cfg.source.postgres.?;
    printStatus("Configuration loaded:\n", .{});
    printStatus("  PostgreSQL: {s}:{}\n", .{ postgres.host, postgres.port });
    printStatus("  Database: {s}\n", .{postgres.database});
    printStatus("  User: {s}\n", .{postgres.user});
    printStatus("  Slot: {s}\n", .{postgres.slot_name});
}

fn validatePostgres(allocator: std.mem.Allocator, cfg: Config) !void {
    const conn_str = try cfg.postgresConnectionString(allocator);
    defer allocator.free(conn_str);

    printStatus("\nValidating PostgreSQL connection and settings...\n", .{});

    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    try validator.connect(conn_str);
    try validator.checkPostgresVersion();
    try validator.checkWalLevel();

    for (cfg.streams) |stream| {
        validator.checkTableExists("public", stream.source.resource) catch |err| {
            printStatus("ERROR: Table validation failed for '{s}': {}\n", .{ stream.source.resource, err });
            return err;
        };
    }

    printStatus("PostgreSQL validation completed successfully!\n", .{});
}
