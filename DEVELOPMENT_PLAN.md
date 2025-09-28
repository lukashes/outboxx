# Outboxx Development Plan

## Development Philosophy: Function First, Optimize Later

Outboxx follows a pragmatic development approach:
1. **Build functional library** with complete feature set
2. **Conduct load testing** to identify bottlenecks
3. **Optimize performance** based on real-world data
4. **Interface design takes priority** over implementation details

This ensures we build the right thing before we build it right.

## Current Status: Foundation Complete ✅

**Major Achievements:**
- ✅ **PostgreSQL Logical Replication**: SQL-based approach with test_decoding plugin
- ✅ **End-to-End Pipeline**: Complete PostgreSQL → Kafka message flow
- ✅ **Memory Safety**: Proper Zig allocator usage and error handling
- ✅ **Integration Testing**: Real PostgreSQL and Kafka with comprehensive test coverage
- ✅ **Multi-Stream Configuration**: TOML-based configuration with validation
- ✅ **Development Environment**: Nix-based isolated setup with Docker Compose

### Phase 1: Foundation ✅ (COMPLETED)
- ✅ Project structure and build.zig with Nix environment
- ✅ PostgreSQL connector with libpq integration
- ✅ Logical replication client for WAL stream connection
- ✅ WAL records decoding and parsing with test_decoding plugin
- ✅ Comprehensive integration tests with real PostgreSQL
- ✅ Memory-safe implementation with proper error handling

### Phase 2: Data Processing 🔄 (IN PROGRESS)
- ✅ Message formatting with JSON serialization
- ✅ TOML configuration support with validation
- ✅ Multi-stream support for different tables
- 📋 Schema registry for table metadata caching
- 📋 Table/column filtering implementation
- 📋 Advanced data transformations

### Phase 3: Kafka Integration ✅ (COMPLETED)
- ✅ Kafka producer with librdkafka integration
- ✅ Basic partitioning by table
- ✅ Integration tests with embedded Kafka consumer
- 📋 Advanced partitioning strategies
- 📋 Error handling with retry/dead letter queue
- 📋 Performance metrics and monitoring

### Phase 4: Operations 📋 (PLANNED)
- 📋 LSN tracking and crash recovery state management
- 📋 Structured logging system
- 📋 Graceful shutdown with replication slots cleanup
- 📋 Production-ready configuration validation

## Future Development Phases

### Phase 5: Load Testing & Validation 📋
Before optimization, thorough testing of functional system:
- Performance baseline measurement (throughput and latency)
- High-volume message scenarios testing
- Resource limits and failure modes testing
- Comparison with existing solutions (Debezium, pglogrepl)

### Phase 6: Performance Optimization 🚀
Data-driven optimization based on load testing results:
- Protocol optimization (migrate from SQL polling to streaming replication)
- Memory optimization (reduce allocations, improve usage patterns)
- I/O optimization (batch processing and async operations)
- CPU optimization (optimize hot paths and reduce overhead)

### Phase 7: Production Features 🏢
Enterprise-ready capabilities:
- Transactional Outbox pattern support
- High availability and failover scenarios
- Monitoring, metrics, and operational visibility
- Advanced configuration options and deployment flexibility

## Learning Goals for Zig
- Memory management with allocators
- C interop with libpq/librdkafka
- Async/await for network operations
- Error handling with error unions
- Performance optimization with comptime

## Implementation Notes

### Key Dependencies (Current Status)
- **libpq** ✅ - PostgreSQL client library for logical replication (integrated)
- **librdkafka** ✅ - High-performance Kafka client (integrated)
- **zig-toml** ✅ - TOML configuration parsing (integrated)
- **zig std.json** ✅ - JSON serialization (using standard library)

### Architecture Decisions
- Use Zig's built-in allocators for memory management
- Leverage C interop for mature libraries (libpq, librdkafka)
- Implement async I/O for concurrent WAL processing and Kafka producing
- Use error unions for robust error handling throughout the pipeline

### Performance Considerations
- Minimize memory allocations in hot paths
- Batch Kafka messages for better throughput
- Use ring buffers for WAL record queuing
- Implement backpressure handling for slow consumers

## Critical Production Improvements

### Phase 1 Enhancements (High Priority)
- **LSN State Persistence**: Implement file-based LSN tracking to prevent data loss on restart
  - Store last processed LSN in local state file
  - Use specific LSN in `pg_logical_slot_get_changes()` instead of NULL
  - Add LSN validation and recovery logic

- **Robust Replication Slot Management**:
  - Check slot existence before creation (`pg_replication_slots` query)
  - Implement graceful slot cleanup on shutdown
  - Monitor replication lag with `pg_stat_replication` queries
  - Handle slot conflicts and auto-recovery

- **Transaction Boundary Handling**:
  - Parse BEGIN/COMMIT records from test_decoding output
  - Group changes by transaction ID (XID)
  - Maintain transaction ordering and atomicity guarantees

### Phase 2 Enhancements (Medium Priority)
- **Consistent Snapshots**: Implement initial consistent snapshot before streaming
  - Create snapshot of existing data when slot is created
  - Ensure no data loss between snapshot and streaming start
  - Handle large table snapshots with pagination

- **Schema Change Detection**:
  - Monitor DDL changes through event triggers or pg_stat_activity
  - Invalidate cached table metadata on schema changes
  - Handle column additions/removals gracefully

- **Advanced Error Handling**:
  - Exponential backoff for PostgreSQL reconnections
  - Circuit breaker pattern for database unavailability
  - Retry logic with configurable limits and timeouts

### Phase 3 Enhancements (Medium Priority)
- **Message Format Improvements**:
  - Generate tombstone events for DELETE operations (Kafka log compaction)
  - Handle primary key updates as DELETE + INSERT pairs
  - Add transaction metadata events for consumer coordination

- **Data Type Handling**:
  - Handle PostgreSQL-specific types (JSON, arrays, custom types)
  - Deal with generated columns (not captured by pgoutput)
  - Process TOAST values and large objects

### Phase 4 Enhancements (Low Priority)
- **Monitoring and Observability**:
  - Metrics for replication lag, throughput, error rates
  - Health checks for slot status and connection state
  - Alerting for critical failures and data loss scenarios

- **Production Readiness**:
  - Configuration validation and defaults
  - Signal handling for graceful shutdown
  - Memory usage monitoring and limits
  - Log rotation and structured logging