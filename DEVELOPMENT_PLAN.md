# ZiCDC Development Plan

## Phase 1: Foundation (2-3 weeks)
1. Setup project structure and build.zig
2. Create PostgreSQL connector with libpq binding/wrapper
3. Implement logical replication client for WAL stream connection
4. Add basic WAL records decoding and parsing

## Phase 2: Data Processing (2-3 weeks)
5. Implement schema registry for table metadata caching
6. Add message formatting with JSON/Avro serialization
7. Create table/column whitelist/blacklist filtering
8. Add simple data transformations and mappings

## Phase 3: Kafka Integration (1-2 weeks)
9. Integrate Kafka producer with librdkafka binding
10. Implement partitioning by primary key/custom logic
11. Add error handling with retry/dead letter queue
12. Create monitoring and performance metrics

## Phase 4: Operations (1-2 weeks)
13. Add YAML/TOML configuration support
14. Implement LSN tracking and crash recovery state management
15. Add structured logging system
16. Implement graceful shutdown with replication slots cleanup

## Learning Goals for Zig
- Memory management with allocators
- C interop with libpq/librdkafka
- Async/await for network operations
- Error handling with error unions
- Performance optimization with comptime

## Implementation Notes

### Key Dependencies
- **libpq** - PostgreSQL client library for logical replication
- **librdkafka** - High-performance Kafka client
- **zig-yaml** or **zig-toml** - Configuration parsing
- **zig-json** - JSON serialization

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