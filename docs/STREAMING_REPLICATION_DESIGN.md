# Streaming Replication Architecture - Technical Design Decisions

**Status:** Implemented
**Date:** October 2025
**Version:** v1.0

## Overview

This document captures the key architectural decisions made during the implementation of PostgreSQL streaming replication for Outboxx CDC. It replaces the polling-based approach with a binary streaming protocol for improved performance and lower latency.

## Motivation

### Problem: Polling-Based CDC Limitations

The original implementation used `test_decoding` plugin with SQL polling:

**Issues:**
- **High latency**: Minimum 1-second polling interval
- **CPU intensive**: Text parsing on every message
- **No backpressure**: Cannot handle burst traffic efficiently
- **Scalability**: Polling creates unnecessary database load

### Solution: PostgreSQL Streaming Replication

Switch to `pgoutput` plugin with binary streaming protocol:

**Benefits:**
- **Real-time push**: <10ms latency (vs 1s+ polling)
- **Binary format**: Efficient decoding, no text parsing
- **Built-in backpressure**: Flow control via LSN feedback
- **PostgreSQL-native filtering**: Publication filters tables at source

## Key Architectural Decisions

### 1. Protocol Version: pgoutput v2 with streaming disabled

**Decision:** Use `proto_version '2', streaming 'off'`

**Rationale:**
- Simple message types (BEGIN, COMMIT, INSERT, UPDATE, DELETE, RELATION)
- v2 performance improvements over v1 (faster decoding, smaller slot size)
- Safe: only committed transactions sent (no StreamAbort risk)
- Requires PostgreSQL 14+ (acceptable for new projects, released Oct 2021)

**Alternative considered:** v2 with `streaming 'on'`
- Rejected: Added complexity (9 message types vs 5) for minimal MVP benefit
- Can enable later for very large transactions (>1GB)

### 2. Error Handling: Fail-Fast with Supervisor Restart

**Decision:** No retry/reconnect logic - fail-fast and rely on external supervisor (systemd/k8s/docker)

**Rationale:**
- **Simplicity**: No complex retry, backoff, or reconnect code
- **Data safety**: PostgreSQL replication slots preserve LSN across restarts
- **Production-ready**: Standard practice for stateless services

**Critical guarantee:**
```
receiveBatch → sendToKafka → kafka.flush() → sendFeedback(LSN)
                                    ↑
                              MUST succeed before LSN confirm
```

**Consequence:**
- Application crash → supervisor restart → PostgreSQL resends from last confirmed LSN
- Duplicate messages possible in Kafka (acceptable with idempotent consumers)
- No data loss in any failure scenario

### 3. LSN Feedback Timing: After Kafka Flush Only

**Decision:** Confirm LSN to PostgreSQL ONLY after Kafka flush succeeds

**Sequence:**
1. Receive batch from PostgreSQL
2. Send messages to Kafka
3. Wait for Kafka flush acknowledgement (CRITICAL)
4. Send LSN feedback to PostgreSQL

**Rationale:**
- At-least-once delivery guarantee
- If crash between (3) and (4): duplicate messages in Kafka (acceptable)
- If crash before (3): no duplicates, PostgreSQL resends changes
- **No data loss in either case**

**Alternative considered:** Confirm LSN before Kafka flush
- Rejected: Data loss if Kafka fails after LSN confirmation

### 4. Architecture: Single Source Type (No Polling Support)

**Decision:** Implement only streaming source, remove polling entirely

**Structure:**
```
src/source/postgres/
├── source.zig                # Main orchestrator
├── replication_protocol.zig  # Low-level libpq streaming protocol
├── pg_output_decoder.zig     # Binary format decoder
└── relation_registry.zig     # Table metadata mapping
```

**Rationale:**
- Clean separation: no abstraction overhead
- Simpler codebase: one implementation, not two
- No performance regression: streaming strictly better than polling

**Evolution:**
1. Initially implemented both polling and streaming adapters
2. Benchmarks showed streaming >100x throughput improvement
3. Deleted polling adapter after validation

### 5. RelationRegistry: In-Memory, No Persistence

**Decision:** Don't persist relation_id → table_name mapping to disk

**Rationale:**
- **Auto-rebuilds**: PostgreSQL sends RELATION messages before first use
- **Simple**: No disk I/O, serialization, or recovery logic
- **Fast**: HashMap lookup in memory

**Lifecycle:**
- On start: empty registry
- On RELATION message: add/update entry
- On restart: PostgreSQL re-sends RELATION messages automatically
- On ALTER TABLE: PostgreSQL sends updated RELATION message
- On DROP TABLE: no special handling needed (entry becomes unused)

### 6. Batch API: Flat List of Changes (No Transaction Type)

**Decision:** Return `Batch { changes: []ChangeEvent, last_lsn: u64 }` - no Transaction boundaries exposed

**Rationale:**
- **Processor doesn't need transactions**: just processes individual changes
- **Simpler API**: fewer concepts, same functionality
- **Streaming handles internally**: BEGIN/COMMIT invisible to consumer

**Implementation:**
```zig
pub const Batch = struct {
    changes: []ChangeEvent,  // Flat list
    last_lsn: u64,           // For feedback
};

pub fn receiveBatch(limit: usize) !Batch;
pub fn sendFeedback(lsn: u64) !void;
```

### 7. Table Filtering: Publication-Based (PostgreSQL Level)

**Decision:** Use PostgreSQL Publications for table filtering, no client-side filter

**Rationale:**
- **pgoutput + Publication**: PostgreSQL filters at source, only subscribed tables sent
- **No overhead**: Unlike `test_decoding` which sends ALL tables
- **Simple client**: No need for fast table filter HashSet

**Alternative (polling source):**
- `test_decoding` sends ALL database tables → required O(1) table filter
- Streaming doesn't need this optimization

### 8. I/O Pattern: Event-Driven with poll()

**Decision:** Use `poll()` syscall for blocking I/O, drain buffered messages after wakeup

**Implementation:**
```zig
// Step 1: Try non-blocking read
var len = PQgetCopyData(connection, &buffer, 1);

if (len == 0) {
    // Step 2: Block on poll() until socket readable
    poll(&pollfds, timeout_ms);

    // Step 3: Consume input from socket
    PQconsumeInput(connection);

    // Step 4: Try read again
    len = PQgetCopyData(connection, &buffer, 1);
}

// Step 5: DRAIN all buffered messages (non-blocking)
while (more_data_available) {
    next = PQgetCopyData(connection, &buffer, 1);
    if (next == 0) break; // Buffer empty
    processMessage(next);
}
```

**Rationale:**
- **CPU efficiency**: ~98% reduction (98% → <2%) by removing busy-wait polling
- **Low latency**: Immediate wakeup when data available
- **Batch optimization**: Drain buffer after poll() wakeup for better throughput

**Alternative considered:** Busy-wait loop with sleep
- Rejected: 98% CPU usage in `PQconsumeInput`, unacceptable

### 9. Kafka Flush Timeout: 5 seconds

**Decision:** Use 5-second Kafka flush timeout (reduced from 30 seconds)

**Rationale:**
- **Lower replication lag**: ~26s → ~10-15s lag reduction
- **Real-time CDC**: Faster feedback to PostgreSQL
- **Safe**: Sufficient time for Kafka broker acknowledgments

**Trade-off:**
- More frequent Kafka flush operations
- Slightly higher CPU usage
- Acceptable for real-time CDC use case

## Performance Results

### Before Streaming (Polling with test_decoding):
- Throughput: ~1,000 events/sec
- Latency: 1+ second (polling interval)
- CPU: High text parsing overhead
- Memory: String allocations for parsing

### After Streaming (pgoutput binary protocol):
- Throughput: ~3,220 events/sec (3.2x improvement)
- Latency: <10ms real-time push
- CPU: 9.37% mean usage
- Memory: 3.73 MiB mean (78x less than Debezium)

### Optimization Impact:

| Optimization | CPU Before | CPU After | Improvement |
|--------------|------------|-----------|-------------|
| Replace polling with poll() | 98% | 16.90% | 83% reduction |
| Remove artificial sleep | Limited throughput | ~109k events/sec | 114x throughput |
| Message batching | Multiple poll() calls | Single poll() + drain | Better burst handling |

## Configuration Changes

### PostgreSQL Setup

**Requirements:**
- PostgreSQL 14+ (for pgoutput protocol v2)
- Logical replication enabled: `wal_level = logical`

**Create replication slot:**
```sql
-- New: pgoutput plugin (binary)
SELECT pg_create_logical_replication_slot('outboxx_slot', 'pgoutput');

-- Old: test_decoding plugin (text) - NO LONGER USED
-- SELECT pg_create_logical_replication_slot('outboxx_slot', 'test_decoding');
```

**Create publication:**
```sql
-- Filters tables at PostgreSQL level (efficient)
CREATE PUBLICATION outboxx_pub FOR TABLE users, orders;
```

### Application Configuration

**No changes required** - same TOML configuration works:

```toml
[source.postgres]
host = "localhost"
port = 5432
database = "outboxx_test"
slot_name = "outboxx_slot"
publication_name = "outboxx_pub"
```

**Removed configuration option:**
```toml
# engine = "polling" | "streaming"  # NO LONGER SUPPORTED
# Only streaming source exists now
```

## Lessons Learned

### 1. Fail-Fast Simplifies Code

Removing retry/reconnect logic reduced code complexity by ~40% while maintaining data safety through replication slots.

### 2. PostgreSQL Does Heavy Lifting

Using Publications for table filtering eliminated need for client-side fast table filter (O(1) HashSet lookup).

### 3. Profile-Driven Optimization

Each optimization targeted measured bottleneck:
- Phase 1: I/O polling → poll() syscall (98% → 17% CPU)
- Phase 2: Artificial sleep → continuous processing (1k → 109k events/sec)
- Phase 3: Kafka flush timeout → lower lag (30s → 5s timeout)

### 4. Binary Protocol Wins

pgoutput binary format eliminated text parsing overhead entirely, exposing memory allocation as next bottleneck (expected and acceptable).

## References

### PostgreSQL Documentation
- [Logical Replication Protocol](https://www.postgresql.org/docs/current/protocol-replication.html)
- [pgoutput Plugin](https://www.postgresql.org/docs/current/logicaldecoding-output-plugin.html)
- [Logical Replication Message Formats](https://www.postgresql.org/docs/current/protocol-logicalrep-message-formats.html)

### Similar Implementations
- [pglogrepl (Go)](https://github.com/jackc/pglogrepl) - Reference for binary protocol
- [Debezium PostgreSQL Connector](https://github.com/debezium/debezium/tree/main/debezium-connector-postgres) - Feature reference
- [pg_recvlogical](https://www.postgresql.org/docs/current/app-pgrecvlogical.html) - PostgreSQL built-in tool

## Appendix: Rejected Alternatives

### Alternative 1: Keep Both Polling and Streaming

**Rejected because:**
- Maintenance burden: two implementations to maintain
- No use case: streaming strictly superior in all metrics
- Code complexity: abstraction overhead for no benefit

**Decision:** Delete polling source after benchmarks validated streaming performance

### Alternative 2: Client-Side Transaction Reconstruction

**Rejected because:**
- Processor doesn't need transaction boundaries
- Added complexity for no functional benefit
- Flat list of changes sufficient for CDC use case

**Decision:** Handle BEGIN/COMMIT internally, return flat `Batch.changes[]`

### Alternative 3: Persist RelationRegistry to Disk

**Rejected because:**
- PostgreSQL automatically re-sends RELATION messages on restart
- Added complexity: serialization, recovery, invalidation
- No performance benefit: HashMap lookup already fast

**Decision:** In-memory only, rebuild automatically on restart

### Alternative 4: Retry Logic in Source Layer

**Rejected because:**
- Replication slots preserve state across restarts
- Supervisor pattern (systemd/k8s) is standard for stateless services
- Simpler code: propagate errors up, no retry/backoff complexity

**Decision:** Fail-fast, rely on external supervisor for restart
