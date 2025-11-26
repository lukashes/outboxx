# Outboxx Development Plan

## Development Philosophy: Function First, Optimize Later

Outboxx follows a pragmatic development approach:
1. **Build functional library** with complete feature set
2. **Conduct load testing** to identify bottlenecks
3. **Optimize performance** based on real-world data
4. **Interface design takes priority** over implementation details

This ensures we build the right thing before we build it right.

## Current Status: Streaming Replication Complete ✅

**Major Achievements:**
- ✅ **PostgreSQL Streaming Replication**: Binary pgoutput protocol with real-time push
- ✅ **End-to-End Pipeline**: Complete PostgreSQL → Kafka message flow
- ✅ **Memory Safety**: Proper Zig allocator usage and error handling
- ✅ **Comprehensive Testing**: Unit, integration, and E2E tests with real services
- ✅ **Multi-Stream Configuration**: TOML-based configuration with validation
- ✅ **Development Environment**: Nix-based isolated setup with Docker Compose
- ✅ **High Performance**: ~105k events/sec, <10 MB memory (70% of Debezium throughput)

### Phase 1: Foundation ✅ (COMPLETED)
- ✅ Project structure and build.zig with Nix environment
- ✅ PostgreSQL connector with libpq integration
- ✅ Logical replication client for WAL stream connection
- ✅ WAL records decoding and parsing with test_decoding plugin
- ✅ Comprehensive integration tests with real PostgreSQL
- ✅ Memory-safe implementation with proper error handling

### Phase 2: Data Processing ✅ (COMPLETED)
- ✅ Message formatting with JSON serialization
- ✅ TOML configuration support with validation
- ✅ Multi-stream support for different tables
- ✅ Relation registry for table metadata (pgoutput)
- 📋 Schema registry for complex type handling
- 📋 Advanced data transformations

### Phase 3: Kafka Integration ✅ (COMPLETED)
- ✅ Kafka producer with librdkafka integration
- ✅ Basic partitioning by table
- ✅ Integration tests with embedded Kafka consumer
- 📋 Advanced partitioning strategies
- 📋 Error handling with retry/dead letter queue
- 📋 Performance metrics and monitoring

### Phase 4: Operations ✅ (COMPLETED)
- ✅ LSN tracking with at-least-once delivery guarantee
- ✅ Structured logging with std.log
- ✅ Graceful shutdown with signal handlers
- ✅ Configuration validation on startup
- ✅ Fail-fast error handling with supervisor restart

## Future Development Phases

### Phase 5: Advanced Features 📋 (PLANNED)
- Schema registry integration for complex types
- Table/column filtering at processor level
- Advanced data transformations and enrichment
- Snapshot support for initial data load

### Phase 6: Production Features 🏢 (PLANNED)
Enterprise-ready capabilities:
- Monitoring, metrics, and operational visibility
- High availability and failover scenarios
- Advanced configuration options
- Performance tuning and optimization

## Learning Goals for Zig
- Memory management with allocators
- C interop with libpq/librdkafka
- Async/await for network operations
- Error handling with error unions
- Performance optimization with comptime

## Implementation Notes

### Key Dependencies
- **libpq** ✅ - PostgreSQL streaming replication protocol (integrated)
- **librdkafka** ✅ - High-performance Kafka client (integrated)
- **zig-toml** ✅ - TOML configuration parsing (integrated)
- **zig std.json** ✅ - JSON serialization (using standard library)

### Architecture Decisions
- Use Zig's built-in allocators for memory management
- Leverage C interop for mature libraries (libpq, librdkafka)
- Event-driven I/O with poll() for efficient network handling
- Fail-fast error handling with supervisor-based restart
- Use error unions for robust error handling throughout the pipeline

### Performance Achievements
- Binary protocol (pgoutput) eliminates text parsing overhead
- Event-driven I/O reduces CPU usage from 98% to <10%
- Arena Allocator for automatic batch memory cleanup
- Async flush/commit in background thread reduces blocking operations
- **Current throughput: ~105k events/sec** (progress: 60k → 85k → 105k, target: 150k to match Debezium)
- Memory footprint: <10 MB
- At-least-once delivery with LSN feedback after Kafka flush

## Production Enhancements (Post-MVP)

### Already Implemented ✅
- ✅ LSN tracking with at-least-once delivery guarantee
- ✅ Replication slot auto-creation and management
- ✅ Transaction boundary handling (BEGIN/COMMIT internally)
- ✅ Graceful shutdown with signal handlers (SIGINT, SIGTERM)
- ✅ Configuration validation on startup
- ✅ Fail-fast error handling with supervisor restart
- ✅ Relation registry for table metadata (auto-rebuilds on restart)

### Planned Improvements 📋

**Snapshot Support:**
- Initial snapshot before streaming replication starts
- Consistent point-in-time data capture
- Handle large tables with pagination

**Advanced Data Types:**
- PostgreSQL-specific types (JSON, arrays, JSONB)
- TOAST value handling for large objects
- Custom type support

**Monitoring and Observability:**
- Metrics for replication lag and throughput
- Health checks for slot status and connection
- Structured metrics export (Prometheus format)

**Schema Change Handling:**
- Detect DDL changes via RELATION messages
- Invalidate cached metadata automatically
- Handle column additions/removals gracefully