const std = @import("std");
const print = std.debug.print;
const KafkaConsumer = @import("kafka/consumer.zig").KafkaConsumer;

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

    print("Kafka Debug Consumer - CDC Message Inspector\n", .{});
    print("=========================================\n\n", .{});

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default topics if none specified
    const topics_to_consume = if (args.len <= 1) blk: {
        print("No topics specified, consuming common CDC topics:\n", .{});
        break :blk &[_][]const u8{
            "public.users",
            "public.orders",
            "public.products",
            "test.kafka.integration",
            "test.e2e.verification",
        };
    } else blk: {
        print("Consuming specified topics:\n", .{});
        break :blk args[1..];
    };

    for (topics_to_consume) |topic| {
        print("  - {s}\n", .{topic});
    }
    print("\n", .{});

    // Create consumer
    var consumer = KafkaConsumer.init(allocator, "localhost:9092", "debug-consumer-group") catch |err| {
        print("Failed to create Kafka consumer: {}\n", .{err});
        print("Make sure Kafka is running on localhost:9092\n", .{});
        return;
    };
    defer consumer.deinit();

    // Subscribe to topics
    consumer.subscribe(topics_to_consume) catch |err| {
        print("Failed to subscribe to topics: {}\n", .{err});
        return;
    };

    print("Connected to Kafka and subscribed to topics\n", .{});
    print("Listening for messages... (Press Ctrl+C to stop)\n\n", .{});

    var message_count: u32 = 0;
    var last_activity = std.time.timestamp();

    while (true) {
        if (consumer.poll(5000)) |message_opt| {
            if (message_opt) |message| {
                defer {
                    var mut_msg = message;
                    mut_msg.deinit(allocator);
                }

                message_count += 1;
                last_activity = std.time.timestamp();

                print("Message #{} received at {}\n", .{ message_count, std.time.timestamp() });
                print("Topic: {s}\n", .{message.topic});
                print("Partition: {}, Offset: {}\n", .{ message.partition, message.offset });
                print("Key: {s}\n", .{message.key orelse "null"});
                print("Payload ({} bytes):\n", .{message.payload.len});

                // Pretty print JSON if possible
                if (std.mem.startsWith(u8, message.payload, "{") and std.mem.endsWith(u8, message.payload, "}")) {
                    print("   JSON Content:\n", .{});
                    print("   {s}\n", .{message.payload});

                    // Try to parse and pretty print key fields
                    parseAndDisplayCDCMessage(message.payload) catch |err| {
                        print("   JSON parsing failed: {}\n", .{err});
                    };
                } else {
                    print("   Raw Content:\n", .{});
                    print("   {s}\n", .{message.payload});
                }

                print("------------------------------------------------\n\n", .{});

                // Commit the message
                consumer.commitSync() catch |err| {
                    print("Failed to commit offset: {}\n", .{err});
                };
            }
        } else |err| {
            switch (err) {
                error.PollTimeout => {
                    const now = std.time.timestamp();
                    if (now - last_activity > 30) {
                        print("No messages for 30 seconds... still listening\n", .{});
                        last_activity = now;
                    }
                    continue;
                },
                else => {
                    print("Consumer error: {}\n", .{err});
                    break;
                },
            }
        }
    }

    print("\nConsumer stopped. Total messages processed: {}\n", .{message_count});
}

fn parseAndDisplayCDCMessage(payload: []const u8) !void {
    // Simple JSON field extraction (not a full parser)
    const operation = extractJSONField(payload, "operation") orelse "unknown";
    const table = extractJSONField(payload, "table") orelse "unknown";
    const schema = extractJSONField(payload, "schema") orelse "unknown";
    const timestamp = extractJSONField(payload, "timestamp") orelse "unknown";

    print("   CDC Analysis:\n", .{});
    print("   Operation: {s}\n", .{operation});
    print("   Schema: {s}\n", .{schema});
    print("   Table: {s}\n", .{table});
    print("   Timestamp: {s}\n", .{timestamp});
}

fn extractJSONField(json: []const u8, field_name: []const u8) ?[]const u8 {
    // Simple JSON field extraction - find "field_name":"value"
    const search_pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":\"", .{field_name}) catch return null;
    defer std.heap.page_allocator.free(search_pattern);

    const start_pos = std.mem.indexOf(u8, json, search_pattern) orelse return null;
    const value_start = start_pos + search_pattern.len;

    const value_end = std.mem.indexOfScalarPos(u8, json, value_start, '"') orelse return null;

    return json[value_start..value_end];
}
