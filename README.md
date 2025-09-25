# Outboxx - Lightweight PostgreSQL Change Data Capture in Zig

Outboxx is a high-performance, resource-efficient Change Data Capture (CDC) tool that streams PostgreSQL Write-Ahead Log (WAL) changes to Apache Kafka. Built in Zig for minimal resource consumption and maximum performance.

**Project Status**: This started as a learning project for Zig programming language, but has the ambition to become a production-ready tool for implementing the Transactional Outbox pattern and general CDC use cases.

## Inspiration and Motivation

This project is inspired by [Debezium](https://debezium.io/), the established leader in Change Data Capture. While Debezium is feature-rich and battle-tested, it often consumes significant resources and introduces complexity. Outboxx aims to provide:

- **Minimal Resource Usage** - Low memory footprint and CPU overhead
- **High Performance** - Native code performance with Zig's zero-cost abstractions
- **Simplicity** - Focused feature set without unnecessary complexity
- **Reliability** - Robust error handling and crash recovery

## Project Goals

### Primary Objectives
- Stream PostgreSQL logical replication changes to Kafka topics
- Support multiple output formats (JSON, Avro)
- Provide configurable table/column filtering
- Maintain exactly-once delivery semantics
- Minimize resource consumption compared to JVM-based solutions

### Target Use Cases
- Real-time data synchronization between microservices
- Event-driven architectures requiring database change streams
- Analytics pipelines needing low-latency data ingestion
- Scenarios where resource efficiency is critical

## Architecture Overview

```
PostgreSQL WAL → Outboxx → Kafka Topics
     ↑              ↑         ↑
Logical Replication  |    Partitioned
   Protocol      Processing    Messages
                 & Filtering
```

### Core Components
- **WAL Reader** - Connects to PostgreSQL logical replication slot
- **Message Processor** - Decodes and transforms WAL records
- **Schema Registry** - Caches table metadata for efficient processing
- **Kafka Producer** - Publishes formatted messages to Kafka
- **State Manager** - Tracks LSN positions for crash recovery

## Comparison with Debezium

| Feature | Outboxx | Debezium |
|---------|--------|----------|
| Runtime | Native binary | JVM (Kafka Connect) |
| Memory Usage | ~10-50MB | ~200-500MB |
| Startup Time | <1s | 10-30s |
| Configuration | Simple YAML | Complex JSON/Properties |
| Extensibility | Limited | Highly extensible |
| Ecosystem | Standalone | Full Kafka Connect ecosystem |

## Configuration Example

```yaml
source:
  host: localhost
  port: 5432
  database: mydb
  user: postgres
  slot_name: outboxx_slot

target:
  brokers: ["localhost:9092"]
  topic_prefix: cdc

tables:
  include:
    - users
    - orders
  exclude_columns:
    - password_hash
    - internal_notes

format: json
batch_size: 1000
flush_interval_ms: 100
```

## Development Status

### Development Philosophy: Function First, Optimize Later

Outboxx follows a pragmatic development approach:
1. **Build functional library** with complete feature set
2. **Conduct load testing** to identify bottlenecks
3. **Optimize performance** based on real-world data
4. **Interface design takes priority** over implementation details

This ensures we build the right thing before we build it right.

### Current Phase: Foundation ✅

The project has successfully implemented the core WAL reader functionality:

- ✅ **PostgreSQL Logical Replication**: Connection and slot management using SQL-based approach
- ✅ **WAL Change Detection**: INSERT, UPDATE, DELETE operations with test_decoding plugin
- ✅ **Message Processing**: WAL message parsing with JSON serialization
- ✅ **Kafka Integration**: Producer and consumer implementation with librdkafka
- ✅ **Comprehensive Testing**: Integration tests with real PostgreSQL and Kafka
- ✅ **Memory-Safe Implementation**: Proper Zig allocator usage and error handling

### Phase 2: Functional Completeness 🔄

Current focus on building a complete, working CDC pipeline:

1. **End-to-End Pipeline** - Complete PostgreSQL → Kafka flow
2. **Configuration System** - YAML-based configuration management
3. **Table Filtering** - Include/exclude tables and columns
4. **Schema Registry** - Table metadata caching and change detection
5. **Error Handling** - Robust failure recovery and logging
6. **Integration Testing** - Real-world scenario validation

### Phase 3: Load Testing & Validation 📋

Before optimization, thorough testing of functional system:

1. **Performance Baseline** - Measure current throughput and latency
2. **Load Testing** - High-volume message scenarios
3. **Stress Testing** - Resource limits and failure modes
4. **Benchmark Comparison** - Compare with existing solutions (Debezium, pglogrepl)
5. **Bottleneck Identification** - Profile and identify optimization targets

### Phase 4: Performance Optimization 🚀

Data-driven optimization phase:

1. **Protocol Optimization** - Migrate from SQL polling to streaming replication protocol
2. **Memory Optimization** - Reduce allocations and improve memory usage patterns
3. **CPU Optimization** - Optimize hot paths and reduce overhead
4. **I/O Optimization** - Batch processing and async operations
5. **Production Readiness** - Monitoring, metrics, and operational features

### Phase 5: Production Features 🏢

Enterprise-ready capabilities:

1. **Transactional Outbox Pattern** - Built-in support for reliable messaging
2. **High Availability** - Failover and replication scenarios
3. **Monitoring & Metrics** - Operational visibility and alerting
4. **Advanced Configuration** - Fine-tuning options and deployment flexibility

## Contributing

This project serves as a learning exercise for the Zig programming language while building a useful tool. Contributions, suggestions, and feedback are welcome as development progresses.

## License and Attribution

This project is licensed under the MIT License - See LICENSE file for details.

### Third-Party Acknowledgments

- **Inspired by [Debezium](https://debezium.io/)**: Outboxx draws architectural inspiration from Debezium's approach to Change Data Capture. Debezium is licensed under the Apache License 2.0.
- **PostgreSQL**: Uses PostgreSQL's logical replication functionality. PostgreSQL is licensed under the PostgreSQL License.
- **Zig Programming Language**: Built with [Zig](https://ziglang.org/), which is licensed under the MIT License.

This project is an independent implementation and is not affiliated with or endorsed by the Debezium project or Red Hat. All implementations are original and developed from scratch using publicly available PostgreSQL documentation and Zig best practices.