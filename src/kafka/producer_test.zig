const std = @import("std");
const testing = std.testing;
const KafkaProducer = @import("producer.zig").KafkaProducer;
const KafkaConsumer = @import("consumer.zig").KafkaConsumer;

test "Kafka integration tests" {
    // These tests REQUIRE Kafka running (use 'make env-up' first)
    // Tests will FAIL if Kafka is not available - this is expected behavior for integration tests
    std.testing.refAllDecls(@This());
}

test "KafkaProducer can initialize and connect to Kafka" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    var producer = try KafkaProducer.init(allocator, "localhost:9092");
    defer producer.deinit();

    // If we get here, producer was created successfully
    try testing.expect(producer.producer != null);
}

test "KafkaProducer can send message to topic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    var producer = try KafkaProducer.init(allocator, "localhost:9092");
    defer producer.deinit();

    const test_topic = "test.kafka.integration";
    const test_key = "test_key";
    const test_message = "{\"operation\":\"INSERT\",\"table\":\"test_table\",\"data\":\"test_data\"}";

    // Send test message
    try producer.sendMessage(test_topic, test_key, test_message);

    // Flush to ensure message is sent
    producer.flush(5000);

    std.debug.print("Successfully sent message to topic: {s}\n", .{test_topic});
}

test "KafkaProducer can send messages to multiple topics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    var producer = try KafkaProducer.init(allocator, "localhost:9092");
    defer producer.deinit();

    const topics = [_][]const u8{ "public.users", "public.orders", "public.products" };
    const test_key = "integration_test";

    for (topics, 0..) |topic, i| {
        const message = try std.fmt.allocPrint(allocator, "{{\"operation\":\"INSERT\",\"table\":\"{s}\",\"id\":{}}}", .{ topic, i + 1 });
        defer allocator.free(message);

        try producer.sendMessage(topic, test_key, message);

        std.debug.print("Sent message to topic: {s}\n", .{topic});
    }

    // Flush all messages
    producer.flush(5000);
    std.debug.print("Successfully flushed messages to {} topics\n", .{topics.len});
}

test "KafkaProducer handles invalid broker gracefully" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Try to connect to invalid broker
    const result = KafkaProducer.init(allocator, "invalid-broker:9092");

    // Should fail gracefully
    if (result) |producer| {
        var mut_producer = producer;
        mut_producer.deinit();
        // If it doesn't fail immediately, that's also fine - librdkafka might connect lazily
        std.debug.print("Producer created with invalid broker (lazy connection)\n", .{});
    } else |err| {
        // Expected to fail
        try testing.expect(err == error.ConfigurationFailed or err == error.ProducerCreationFailed);
        std.debug.print("Producer correctly failed with invalid broker: {}\n", .{err});
    }
}

test "KafkaProducer memory management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create and destroy multiple producers to test memory management
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        var producer = try KafkaProducer.init(allocator, "localhost:9092");
        defer producer.deinit();

        // Send a test message
        const topic = try std.fmt.allocPrint(allocator, "test.memory.{}", .{i});
        defer allocator.free(topic);

        const message = try std.fmt.allocPrint(allocator, "{{\"test\":\"memory_{}\"}}", .{i});
        defer allocator.free(message);

        try producer.sendMessage(topic, "memory_test", message);

        producer.flush(1000);
    }

    std.debug.print("Memory management test completed successfully\n", .{});
}

test "Producer-Consumer end-to-end message flow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.panic("Memory leak in test!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Create producer
    var producer = try KafkaProducer.init(allocator, "localhost:9092");
    defer producer.deinit();

    // Create consumer
    var consumer = try KafkaConsumer.init(allocator, "localhost:9092", "test-group-e2e");
    defer consumer.deinit();

    const test_topic = "test.e2e.verification";
    const test_topics = [_][]const u8{test_topic};

    // Subscribe consumer to topic
    try consumer.subscribe(&test_topics);

    // Send test message
    const test_message = "{\"operation\":\"INSERT\",\"table\":\"users\",\"data\":\"id=123 name='Test User'\",\"timestamp\":1758709200}";
    try producer.sendMessage(test_topic, "test-key", test_message);

    // Flush to ensure message is sent
    producer.flush(5000);
    std.debug.print("Message sent to topic: {s}\n", .{test_topic});

    // Poll for the message with timeout
    var attempts: u32 = 0;
    const max_attempts = 10;

    while (attempts < max_attempts) : (attempts += 1) {
        if (consumer.poll(2000)) |message_opt| {
            if (message_opt) |message| {
                defer {
                    var mut_msg = message;
                    mut_msg.deinit(allocator);
                }

                std.debug.print("Received message from topic: {s}\n", .{message.topic});
                std.debug.print("  Partition: {}, Offset: {}\n", .{ message.partition, message.offset });
                std.debug.print("  Key: {s}\n", .{message.key orelse "null"});
                std.debug.print("  Payload: {s}\n", .{message.payload});

                // Verify it's our message
                try testing.expectEqualStrings(test_topic, message.topic);
                try testing.expectEqualStrings("test-key", message.key.?);
                try testing.expectEqualStrings(test_message, message.payload);

                // Commit the message
                consumer.commitSync() catch {};

                std.debug.print("End-to-end test successful: message sent and received!\n", .{});
                return;
            }
        } else |err| {
            if (err != error.PollTimeout) {
                return err;
            }
        }

        std.debug.print("Attempt {}/{}: No message yet, continuing...\n", .{ attempts + 1, max_attempts });
    }

    // If we didn't receive our message, the test should fail
    try testing.expect(false); // Fail the test if message wasn't received
}
