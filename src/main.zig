const std = @import("std");
const config_mod = @import("config/config.zig");
const Config = config_mod.Config;
const Stream = config_mod.Stream;
const Processor = @import("processor/processor.zig").Processor;
const PostgresSource = @import("source/postgres/source.zig").PostgresSource;
const SnapshotReader = @import("source/postgres/snapshot.zig").SnapshotReader;
const kafka_producer = @import("sink/kafka/producer.zig");
const KafkaProducer = kafka_producer.KafkaProducer;
const PostgresValidator = @import("source/postgres/validator.zig").PostgresValidator;
const builtin = @import("builtin");
const posix = std.posix;
const constants = @import("constants.zig");
const observability = @import("observability/observability.zig");
const Observability = observability.Observability;

// Log level is a build option (-Dlog_level=..., default info), so lower levels
// are compiled out of Release/prod. The load stand builds with debug.
pub const std_options: std.Options = .{
    .log_level = constants.LOG_LEVEL,
};

pub const CliError = error{
    NoConfigPath,
};

const CliAction = enum {
    run,
    help,
    version,
};

const Cli = struct {
    action: CliAction = .run,
    config_path: ?[]const u8 = null,
};

var shutdown_requested = std.atomic.Value(bool).init(false);

// Stdout writes need an Io; kept here so printStatus/printBanner stay
// parameterless. TODO: thread `io` through an explicit app context instead.
var stdout_io: std.Io = undefined;

pub fn main(init: std.process.Init) void {
    stdout_io = init.io;
    run(init) catch |err| {
        std.log.err("Fatal error: {}", .{err});
        std.process.exit(1);
    };
    std.process.exit(0);
}

fn run(init: std.process.Init) !void {
    // Debug: DebugAllocator for leak detection. Release: libc allocator
    // (already linked), much faster on the per-change hot path.
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator, const is_debug = switch (builtin.mode) {
        .Debug => .{ debug_allocator.allocator(), true },
        else => .{ std.heap.c_allocator, false },
    };
    defer if (is_debug) {
        if (debug_allocator.deinit() == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    };

    const cli = try parseCli(init.minimal.args, allocator);
    defer if (cli.config_path) |path| allocator.free(path);

    switch (cli.action) {
        .help => {
            printHelp();
            return;
        },
        .version => {
            printVersion();
            return;
        },
        .run => {},
    }

    printBanner();

    const config_file_path = cli.config_path orelse {
        std.log.warn("config file is required. Use --config <path>", .{});
        return CliError.NoConfigPath;
    };

    printStatus("Loading configuration from: {s}\n", .{config_file_path});
    var parsed = try Config.loadFromTomlFile(init.io, allocator, config_file_path);
    defer parsed.deinit();
    const config = parsed.value;

    try config.validate(allocator);

    const conninfo = try config.loadPostgresConninfo(allocator, init.environ_map);
    defer allocator.free(conninfo);

    const kafka_sasl_pw = try config.loadKafkaSaslPassword(allocator, init.environ_map);
    defer if (kafka_sasl_pw) |p| allocator.free(p);

    printConfigInfo(config);

    // Metrics/health are no-ops unless [observability] is configured, so the
    // rest of the wiring never branches on it.
    var obs = if (config.observability != null)
        try Observability.init(allocator, init.io)
    else
        Observability.noop();
    defer obs.deinit();

    try validatePostgres(allocator, config, conninfo);

    const postgres = config.source.postgres.?;

    setupSignalHandlers();

    printStatus("\nStarting CDC processor...\n", .{});
    printStatus("Starting processor for {} stream(s)...\n", .{config.streams.len});
    printStatus("Using PostgreSQL streaming replication (pgoutput protocol)\n", .{});

    var source = PostgresSource.init(allocator, postgres.slot_name, postgres.publication_name);
    // NOTE: source will be deinit'd by processor.deinit()

    printStatus("Connecting to PostgreSQL streaming replication...\n", .{});
    // Connect and ensure the slot exists, without streaming yet, so the initial
    // snapshot (if any) runs under the slot's exported snapshot first. want_snapshot
    // also drives interrupted-snapshot recovery on the slot (see source.ensureSlot).
    const want_snapshot = config.wantsInitialSnapshot();
    try source.connect(conninfo, want_snapshot);

    // Capture before the source is moved into the processor. A freshly created
    // slot exposes its start LSN and exported snapshot; stream from that LSN so we
    // begin exactly at the slot's start. An existing slot exposes neither, so
    // resume from its confirmed position ("0/0") and run no snapshot.
    const start_lsn = source.startLsn() orelse "0/0";
    const snapshot_name = source.snapshotName();

    const producer = try initKafkaProducer(allocator, config.sink.kafka.?, kafka_sasl_pw);
    // NOTE: producer will be deinit'd by processor.deinit()

    var processor = Processor.init(allocator, source, producer, config.streams, &obs);
    defer processor.deinit();

    // Initial snapshot before streaming: only on a freshly created slot, only in
    // `initial` mode, and only for streams opting into `read`. START_REPLICATION
    // (below) invalidates the exported snapshot, so it must follow this. A false
    // return means a shutdown signal interrupted the snapshot; the marker is left in
    // place, so stop here and let the next start redo the bootstrap rather than
    // stream past unread rows.
    const snapshot_done = try maybeRunInitialSnapshot(allocator, init.io, config, &processor, conninfo, snapshot_name, start_lsn, &shutdown_requested);
    if (!snapshot_done) {
        printStatus("\nInitial snapshot interrupted; the bootstrap will restart on the next launch.\n", .{});
        return;
    }

    // Drops the snapshot marker (back to one publication) and starts streaming.
    try processor.beginReplication(start_lsn);

    printStatus("\nProcessor initialized successfully with slot: {s}\n", .{postgres.slot_name});
    printStatus("\nCDC processor started successfully!\n", .{});
    printStatus("Monitoring WAL changes from {} stream(s)\n", .{config.streams.len});
    for (config.streams) |stream| {
        printStatus("  - {s} -> {s}\n", .{ stream.source.resource, stream.sink.destination });
    }
    printStatus("Using publication: {s}\n", .{postgres.publication_name});
    printStatus("Press Ctrl+C to stop gracefully.\n\n", .{});

    // Serve /metrics + health on a background worker while the receive loop runs;
    // the future is canceled on shutdown, which unblocks its accept().
    if (config.observability) |obs_cfg| {
        printStatus("Observability endpoints on http://{s}:{d} (/metrics, /healthz, /readyz)\n\n", .{ obs_cfg.address, obs_cfg.port });
        var metrics_future = try init.io.concurrent(observability.serve, .{
            init.io, &obs, obs_cfg.address, obs_cfg.port, &shutdown_requested,
        });
        defer {
            std.log.debug("main: cancelling metrics server", .{});
            metrics_future.cancel(init.io);
            std.log.debug("main: metrics server cancelled", .{});
        }
        try processor.startStreaming(init.io, &shutdown_requested);
    } else {
        try processor.startStreaming(init.io, &shutdown_requested);
    }
}

// Build the Kafka sink from config, deriving librdkafka's security.protocol from the
// tls/sasl axes, and fail fast if the broker is unreachable at startup. The returned
// producer is owned by the caller (handed to the processor, which deinits it).
fn initKafkaProducer(allocator: std.mem.Allocator, kafka: config_mod.KafkaSink, sasl_password: ?[]const u8) !KafkaProducer {
    const brokers_str = try std.mem.join(allocator, ",", kafka.brokers);
    defer allocator.free(brokers_str);

    // SASL creds and the CA are forwarded only when their axis is active.
    const security: kafka_producer.Security = .{
        .protocol = kafka.securityProtocol(),
        .sasl_mechanism = if (kafka.sasl) |s| s.mechanism else null,
        .sasl_username = if (kafka.sasl) |s| s.username else null,
        .sasl_password = sasl_password,
        .ssl_ca_location = if (kafka.tls) kafka.tls_ca_location else null,
    };

    var producer = try KafkaProducer.init(allocator, brokers_str, security);
    errdefer producer.deinit();

    try producer.testConnection();
    return producer;
}

// Run the initial snapshot when it applies. Returns true when the snapshot is not
// needed or ran to completion, false when a shutdown signal interrupted it (the
// caller then stops instead of streaming). It applies only when the slot was created
// this run (snapshot_name is set), the mode is `initial`, and at least one stream
// lists `read`. The reader opens a second, regular connection and binds it to the
// slot's exported snapshot, so the replication connection must stay idle (no
// START_REPLICATION) until this returns.
fn maybeRunInitialSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    processor: *Processor,
    conninfo: []const u8,
    snapshot_name: ?[]const u8,
    start_lsn: []const u8,
    stop_signal: *std.atomic.Value(bool),
) !bool {
    // No exported snapshot means the slot already existed, so there is nothing to
    // bootstrap (a snapshot is only consistent with a freshly created slot).
    const snap = snapshot_name orelse return true;

    if (!config.wantsInitialSnapshot()) return true;

    const resources = try collectReadResources(allocator, config.streams);
    defer allocator.free(resources);
    if (resources.len == 0) return true;

    printStatus("\nRunning initial snapshot for {} resource(s)...\n", .{resources.len});

    // meta.timestamp for READ rows: the snapshot's wall-clock start. meta.lsn is
    // the slot's start LSN, so a snapshot row shares the dedup boundary with the
    // first streamed change.
    const timestamp = std.Io.Timestamp.now(io, .real).toSeconds();
    var reader = SnapshotReader.init(allocator, snap, start_lsn, timestamp);
    defer reader.deinit();
    try reader.connect(conninfo);

    const completed = try processor.runInitialSnapshot(&reader, resources, stop_signal);
    if (completed) printStatus("Initial snapshot complete.\n", .{});
    return completed;
}

// The distinct resources of streams that opt into `read`, so a table read by
// several streams is snapshotted once. Caller owns the returned slice; the
// resource strings are borrowed from the config.
fn collectReadResources(allocator: std.mem.Allocator, streams: []const Stream) ![]const []const u8 {
    var resources = std.ArrayList([]const u8).empty;
    errdefer resources.deinit(allocator);

    for (streams) |stream| {
        if (!stream.hasReadOperation()) continue;

        var seen = false;
        for (resources.items) |r| {
            if (std.mem.eql(u8, r, stream.source.resource)) {
                seen = true;
                break;
            }
        }
        if (!seen) try resources.append(allocator, stream.source.resource);
    }

    return resources.toOwnedSlice(allocator);
}

// Print user-facing messages to stdout. Use for status/config output; logs and
// diagnostics go through std.log.* (stderr).
fn printStatus(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(stdout_io, &buf);
    const w = &stdout_writer.interface;
    w.print(fmt, args) catch |err| {
        std.log.warn("Failed to write to stdout: {}", .{err});
        return;
    };
    w.flush() catch |err| {
        std.log.warn("Failed to flush stdout: {}", .{err});
    };
}

fn handleShutdownSignal(_: posix.SIG) callconv(.c) void {
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

fn printBanner() void {
    printStatus("{s} - {s}\n", .{ constants.APP_NAME, constants.DESCRIPTION });
    printStatus("Version: {s}\n", .{constants.VERSION});
    printStatus("Zig: {s}\n", .{builtin.zig_version_string});
    printStatus("Build: {s}\n\n", .{@tagName(constants.BUILD_MODE)});
}

fn printVersion() void {
    printStatus("outboxx {s}\n", .{constants.VERSION});
}

fn printHelp() void {
    printStatus(
        \\Outboxx - PostgreSQL Change Data Capture with Kafka
        \\
        \\Usage:
        \\  outboxx --config <path>
        \\  outboxx --version
        \\  outboxx --help
        \\
        \\Options:
        \\  --config, -c <path>  TOML configuration file
        \\  --version           Print version and exit
        \\  --help, -h          Print this help and exit
        \\
    , .{});
}

fn parseCli(args: std.process.Args, allocator: std.mem.Allocator) !Cli {
    var it = args.iterate();
    defer it.deinit();

    var cli = Cli{};

    _ = it.next(); // skip executable name (argv[0])
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cli.action = .help;
            return cli;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            cli.action = .version;
            return cli;
        }
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            if (it.next()) |path| {
                if (cli.config_path) |old_path| allocator.free(old_path);
                cli.config_path = try allocator.dupe(u8, path);
            }
        }
    }

    return cli;
}

fn printConfigInfo(cfg: Config) void {
    const postgres = cfg.source.postgres.?;
    printStatus("Configuration loaded:\n", .{});
    printStatus("  PostgreSQL connection from ${s}\n", .{postgres.connection_env});
    printStatus("  Slot: {s}\n", .{postgres.slot_name});
    printStatus("  Publication: {s}\n", .{postgres.publication_name});
}

fn validatePostgres(allocator: std.mem.Allocator, cfg: Config, conninfo: []const u8) !void {
    printStatus("\nValidating PostgreSQL connection and settings...\n", .{});

    var validator = PostgresValidator.init(allocator);
    defer validator.deinit();

    try validator.connect(conninfo);
    try validator.checkPostgresVersion();
    try validator.checkWalLevel();

    for (cfg.streams) |stream| {
        const resource = stream.source.resource;

        validator.checkTableExists(resource) catch |err| {
            printStatus("ERROR: Table validation failed for '{s}': {}\n", .{ resource, err });
            return err;
        };

        // A missing routing key column would silently collapse partitioning.
        const routing_key = stream.sink.routing_key;
        validator.checkColumnExists(resource, routing_key) catch |err| {
            printStatus("ERROR: Routing key validation failed for '{s}' (column '{s}'): {}\n", .{ resource, routing_key, err });
            return err;
        };

        // Only a stream that tracks DELETE needs REPLICA IDENTITY FULL, so the
        // deleted row carries all columns.
        if (stream.hasDeleteOperation()) {
            validator.checkReplicaIdentity(resource) catch |err| {
                printStatus("ERROR: Replica identity validation failed for '{s}': {}\n", .{ resource, err });
                return err;
            };
        }
    }

    printStatus("PostgreSQL validation completed successfully!\n", .{});
}
