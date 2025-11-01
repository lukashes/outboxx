#!/usr/bin/env python3
"""
Kafka CDC Metrics Exporter for Prometheus - Dual CDC Comparison

Reads CDC events from both Outboxx and Debezium topics, calculates separate metrics:
- Event count per CDC solution (INSERT/UPDATE/DELETE only)
- CDC replication lag per solution (kafka_timestamp - event_timestamp)
- Events per operation type per solution

Lag calculation uses Kafka message timestamp (when Kafka received the message)
for accurate CDC performance measurement, independent of consumer clock drift.
"""

import json
import time
import os
from datetime import datetime
from collections import Counter, defaultdict
from kafka import KafkaConsumer
from prometheus_client import start_http_server, Gauge, Counter as PromCounter

# Prometheus metrics for Outboxx
outboxx_events_total = PromCounter(
    'outboxx_events_total',
    'Total CDC events processed by Outboxx',
    ['operation']
)
outboxx_replication_lag = Gauge(
    'outboxx_replication_lag_seconds',
    'CDC replication lag for Outboxx (kafka_timestamp - event_timestamp)'
)
outboxx_last_event_timestamp = Gauge(
    'outboxx_last_event_timestamp',
    'Timestamp of last processed event from Outboxx'
)

# Prometheus metrics for Debezium
debezium_events_total = PromCounter(
    'debezium_events_total',
    'Total CDC events processed by Debezium',
    ['operation']
)
debezium_replication_lag = Gauge(
    'debezium_replication_lag_seconds',
    'CDC replication lag for Debezium (kafka_timestamp - event_timestamp)'
)
debezium_last_event_timestamp = Gauge(
    'debezium_last_event_timestamp',
    'Timestamp of last processed event from Debezium'
)

# Common metrics
kafka_messages_total = PromCounter(
    'cdc_kafka_messages_total',
    'Total messages read from Kafka by CDC solution',
    ['cdc_solution']
)

# Configuration
KAFKA_BROKERS = os.getenv('KAFKA_BROKERS', 'kafka:9092').split(',')
KAFKA_TOPICS = ['outboxx.bench_events', 'debezium.public.bench_events']
METRICS_PORT = 8000

# Stats per CDC solution
stats = {
    'outboxx': {
        'operations': Counter(),
        'last_timestamp': None,
        'lag_sum': 0,
        'lag_count': 0,
    },
    'debezium': {
        'operations': Counter(),
        'last_timestamp': None,
        'lag_sum': 0,
        'lag_count': 0,
    }
}


def parse_timestamp(ts_str):
    """Parse PostgreSQL timestamp to Unix timestamp"""
    try:
        # Check if it's a Unix timestamp in microseconds (Debezium format)
        if isinstance(ts_str, (int, float)):
            # Convert microseconds to seconds
            return ts_str / 1_000_000.0

        # Format: "2025-10-06 15:42:41.425528" (Outboxx format)
        dt = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S.%f")
        return dt.timestamp()
    except (ValueError, AttributeError, TypeError):
        return None


def detect_cdc_solution(topic):
    """Detect CDC solution based on topic name"""
    if 'outboxx' in topic:
        return 'outboxx'
    elif 'debezium' in topic:
        return 'debezium'
    else:
        return 'unknown'


def process_message(msg):
    """Process Kafka message and update metrics"""
    try:
        data = json.loads(msg.value.decode('utf-8'))

        # Detect CDC solution from topic
        cdc_solution = detect_cdc_solution(msg.topic)
        if cdc_solution == 'unknown':
            return False

        # Increment total messages for this CDC solution
        kafka_messages_total.labels(cdc_solution=cdc_solution).inc()

        # Get operation type - support both Outboxx and Debezium formats
        # Outboxx: {"op": "INSERT", "data": {...}, "meta": {...}}
        # Debezium: {"id": 1, "__op": "c", "__source_ts_ms": 123, ...}
        op = data.get('op')  # Outboxx format
        if not op:
            # Debezium format: __op is "c"/"u"/"d"
            debezium_op = data.get('__op', 'UNKNOWN')
            op_map = {'c': 'INSERT', 'u': 'UPDATE', 'd': 'DELETE', 'r': 'READ'}
            op = op_map.get(debezium_op, debezium_op)

        # Only count INSERT/UPDATE/DELETE (ignore BEGIN/COMMIT/KEEPALIVE)
        if op in ('INSERT', 'UPDATE', 'DELETE'):
            # Update metrics for specific CDC solution
            if cdc_solution == 'outboxx':
                outboxx_events_total.labels(operation=op).inc()
            elif cdc_solution == 'debezium':
                debezium_events_total.labels(operation=op).inc()

            stats[cdc_solution]['operations'][op] += 1

            # Extract event_timestamp - support both formats
            # Outboxx: data.data.event_timestamp
            # Debezium: data.event_timestamp (flattened)
            event_data = data.get('data', {})
            ts_str = event_data.get('event_timestamp')

            # If not in data section, try top level (Debezium)
            if not ts_str:
                ts_str = data.get('event_timestamp')

            if ts_str:
                event_ts = parse_timestamp(ts_str)
                if event_ts:
                    # Get Kafka message timestamp (when Kafka received the message)
                    # msg.timestamp is in milliseconds
                    kafka_ts = msg.timestamp / 1000.0 if msg.timestamp else None

                    if kafka_ts:
                        # Calculate CDC lag: kafka_timestamp - event_timestamp
                        # This measures: time from DB event to Kafka arrival
                        cdc_lag = kafka_ts - event_ts

                        if cdc_lag >= 0:  # Only positive lag makes sense
                            # Update metrics for specific CDC solution
                            if cdc_solution == 'outboxx':
                                outboxx_replication_lag.set(cdc_lag)
                                outboxx_last_event_timestamp.set(event_ts)
                            elif cdc_solution == 'debezium':
                                debezium_replication_lag.set(cdc_lag)
                                debezium_last_event_timestamp.set(event_ts)

                            stats[cdc_solution]['last_timestamp'] = event_ts
                            stats[cdc_solution]['lag_sum'] += cdc_lag
                            stats[cdc_solution]['lag_count'] += 1

                            return True

        return False

    except (json.JSONDecodeError, KeyError, TypeError) as e:
        print(f"Error processing message: {e}")
        return False


def main():
    print(f"Starting Kafka CDC Metrics Exporter (Dual CDC Comparison)")
    print(f"Kafka brokers: {KAFKA_BROKERS}")
    print(f"Topics: {KAFKA_TOPICS}")
    print(f"  - outboxx.bench_events         → outboxx_* metrics")
    print(f"  - debezium.public.bench_events → debezium_* metrics")
    print(f"Metrics endpoint: http://0.0.0.0:{METRICS_PORT}/metrics")

    # Start Prometheus HTTP server
    start_http_server(METRICS_PORT)
    print(f"Prometheus metrics server started on port {METRICS_PORT}")

    # Wait for Kafka to be ready
    print("Waiting for Kafka...")
    time.sleep(5)

    # Create Kafka consumer with unique group_id to always read from beginning
    # Using timestamp-based group_id ensures fresh start on each restart
    import uuid
    unique_group_id = f'cdc-metrics-exporter-{uuid.uuid4()}'
    print(f"Using consumer group: {unique_group_id}")

    consumer = KafkaConsumer(
        *KAFKA_TOPICS,  # Subscribe to multiple topics
        bootstrap_servers=KAFKA_BROKERS,
        group_id=unique_group_id,  # Unique group to force earliest offset
        auto_offset_reset='earliest',  # Read from beginning (including Debezium snapshot)
        enable_auto_commit=False,  # Don't persist offsets
        value_deserializer=lambda m: m,  # Keep as bytes, we'll decode manually
        consumer_timeout_ms=1000,  # Return after 1s if no messages
    )

    print(f"Connected to Kafka, consuming from topics: {KAFKA_TOPICS}")
    print("Processing messages...")

    message_count = 0
    last_stats_time = time.time()

    try:
        while True:
            for message in consumer:
                process_message(message)
                message_count += 1

                # Print stats every 10 seconds
                if time.time() - last_stats_time >= 10:
                    print(f"\n=== Stats after {message_count} messages ===")
                    for cdc, cdc_stats in stats.items():
                        avg_lag = cdc_stats['lag_sum'] / cdc_stats['lag_count'] if cdc_stats['lag_count'] > 0 else 0
                        print(f"{cdc.upper():>10}: Operations: {dict(cdc_stats['operations'])}, Avg lag: {avg_lag:.3f}s")
                    last_stats_time = time.time()

            # No messages in last 1s, sleep a bit
            time.sleep(0.1)

    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        consumer.close()
        print(f"\nProcessed {message_count} total messages")
        print("Final stats:")
        for cdc, cdc_stats in stats.items():
            print(f"  {cdc.upper()}: {dict(cdc_stats['operations'])}")


if __name__ == '__main__':
    main()
