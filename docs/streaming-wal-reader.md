# Streaming WAL Reader - Implementation Plan

**Status:** Planning
**Author:** Architecture Team
**Date:** 2025-10-10
**Version:** MVP v1.0

## Table of Contents

1. [Overview](#overview)
2. [Motivation](#motivation)
3. [Architecture](#architecture)
4. [Components](#components)
5. [Implementation Plan](#implementation-plan)
6. [Integration](#integration)
7. [References](#references)

---

## Overview

This document describes the implementation plan for a new **Streaming WAL Reader** based on PostgreSQL's logical replication protocol with the `pgoutput` plugin. The new implementation will replace the current polling-based approach (`test_decoding` + `pg_logical_slot_peek_changes`) with a streaming, binary protocol for improved performance and lower latency.

### Key Decisions

1. **Two Separate Sources** - `postgres_polling` (temporary) and `postgres_streaming` (permanent)
2. **Protocol v2 + streaming disabled** - Best balance (simple + efficient, no StreamAbort risk)
3. **Simple API** - `Batch { changes: []ChangeEvent, last_lsn: u64 }` (no Transaction type)
4. **Fail-fast error handling** - No retry logic, rely on supervisor restart
5. **LSN feedback after Kafka flush** - Guarantee no data loss
6. **Iterative approach** - Validate API with polling adapter first, then implement streaming

### Goals

- ✅ **Real-time streaming** instead of polling (push vs pull)
- ✅ **Binary protocol** instead of text parsing (pgoutput vs test_decoding)
- ✅ **Lower latency** (<10ms instead of 1s+ polling interval)
- ✅ **Lower CPU usage** (binary decode vs text parsing)
- ✅ **Scalable architecture** (ready for future enhancements)

### Non-Goals (Post-MVP)

- ❌ Initial snapshot support (will be added later)
- ❌ Async callbacks (synchronous pull API for MVP)
- ❌ Connection pooling (single connection sufficient)
- ❌ Advanced schema caching (minimal relation_id mapping only)
- ❌ UPDATE old values support (REPLICA IDENTITY DEFAULT only)

---

## Motivation

### Current Approach (test_decoding + polling)

**How it works:**
```
┌─────────────┐
│  Processor  │
└──────┬──────┘
       │ poll every 1s
       ↓
┌─────────────────────────────┐
│ WalReader                   │
│ peekChanges(limit)          │
└──────┬──────────────────────┘
       │ SQL: pg_logical_slot_peek_changes()
       ↓
┌─────────────────────────────┐
│ PostgreSQL                  │
│ test_decoding plugin        │
│ Returns: text format        │
└─────────────────────────────┘
```

**Problems:**
1. ❌ **Polling overhead** - Query every 1 second, inefficient
2. ❌ **Text parsing** - `test_decoding` returns text: `"table public.users: INSERT: id[integer]:1"`
3. ❌ **High latency** - Minimum 1 second delay
4. ❌ **No backpressure** - No flow control mechanism
5. ❌ **Memory inefficient** - String copying for parsing
6. ❌ **CPU intensive** - Text parsing on every message

### New Approach (pgoutput + streaming)

**How it works:**
```
┌─────────────┐
│  Processor  │
└──────┬──────┘
       │ async stream
       ↓
┌──────────────────────────────────────┐
│ StreamingWalReader                   │
│ - Streaming Replication Protocol     │
│ - pgoutput plugin (binary)           │
│ - Real-time push                     │
└──────┬───────────────────────────────┘
       │ CopyBoth mode (bidirectional)
       ↓
┌──────────────────────────────────────┐
│ PostgreSQL Replication Protocol      │
│ - Streaming (push, not pull)         │
│ - pgoutput: binary format            │
│ - Feedback messages (LSN confirm)    │
└──────────────────────────────────────┘
```

**Benefits:**

| Feature | Old (test_decoding) | New (pgoutput streaming) |
|---------|---------------------|--------------------------|
| **Protocol** | SQL polling | Streaming replication |
| **Format** | Text (parsing required) | Binary (structured) |
| **Latency** | 1s+ (poll interval) | <10ms (real-time push) |
| **CPU** | High (text parsing) | Low (binary decode) |
| **Backpressure** | ❌ No | ✅ Flow control |
| **Memory** | High (string copies) | Low (zero-copy possible) |

---

## Architecture

### Module Structure

Two separate source implementations (no shared code):

```
src/source/
├── postgres_polling/              # Old (temporary, for benchmarks)
│   ├── source.zig                # Clean adapter API
│   ├── wal_reader.zig            # Current implementation (moved)
│   └── wal_parser.zig            # Current parser (moved)
│
└── postgres_streaming/            # New (permanent)
    ├── source.zig                # Main API (same interface as polling)
    ├── replication_protocol.zig  # Low-level libpq protocol
    ├── pgoutput_decoder.zig      # Binary format decoder
    └── relation_registry.zig     # Relation ID -> Table name mapping
```

**Design Philosophy:**
- Two completely independent source types
- Same public API (duck typing via comptime)
- Processor works with both via generic code
- After benchmarks: delete `postgres_polling/` entirely

### Data Flow (Streaming Source)

```
PostgreSQL (pgoutput binary)
    │
    ↓ [CopyBoth mode - streaming]
ReplicationProtocol (low-level libpq)
    │
    ↓ [RawMessage: LSN + binary data]
PgOutputDecoder (binary parser)
    │
    ↓ [WalMessage: BEGIN/INSERT/COMMIT/etc]
PostgresStreamingSource (orchestration)
    │
    ├─→ RelationRegistry (relation_id -> table)
    │
    ↓ [Batch: changes + LSN]
Processor (business logic)
```

### Data Flow (Polling Source)

```
PostgreSQL (test_decoding text)
    │
    ↓ [SQL: pg_logical_slot_peek_changes()]
WalReader (old implementation)
    │
    ↓ [Text: "table public.users: INSERT..."]
WalParser (text parser)
    │
    ↓ [ChangeEvent]
PostgresPollingSource (adapter)
    │
    ↓ [Batch: changes + LSN]
Processor (business logic)
```

**Key Insight:** Both sources return identical `Batch` structure - Processor doesn't know the difference!

---

## Error Handling Strategy

### Fail-Fast Philosophy

**Outboxx Design:** Fail-fast with supervisor-based restart (systemd/k8s/docker)

**Rationale:**
- PostgreSQL replication slots preserve LSN position across restarts
- Supervisor handles process restart automatically
- Simple code - no retry/backoff/reconnect complexity in WAL reader

**Error Categories:**

| Error Type | Action | Rationale |
|------------|--------|-----------|
| Connection error | Exit(1) | Supervisor restarts, reconnect from last LSN |
| Decode error | Exit(1) | Data corruption - needs investigation |
| Kafka error | Exit(1) | Cannot proceed without sink |
| Timeout | Exit(1) | Connection issue - let supervisor handle |

**No Data Loss Guarantee:**

The critical sequence ensures no data loss:

```zig
// 1. Receive batch from PostgreSQL
var batch = try source.receiveBatch(1000);

// 2. Send to Kafka
for (batch.changes) |change_event| {
    try kafka.send(topic, key, payload);
}

// 3. Wait for Kafka acknowledgement (CRITICAL!)
try kafka.flush();

// 4. Confirm LSN to PostgreSQL ONLY after Kafka flush
try source.sendFeedback(batch.last_lsn);

// If crash between step 4 and restart:
// → PostgreSQL re-sends from last confirmed LSN
// → Duplicate messages in Kafka (acceptable, idempotency at consumer)
// → No data loss
```

**Architecture Simplification:**

```zig
// ❌ OLD (complex retry logic - NOT NEEDED):
pub fn receiveBatch(limit: usize) !Batch {
    var retries: u8 = 0;
    while (retries < MAX_RETRIES) {
        self.protocol.receiveMessage() catch |err| {
            retries += 1;
            std.time.sleep(backoff_ms);
            try self.reconnect();
            continue;
        };
    }
}

// ✅ NEW (fail-fast):
pub fn receiveBatch(limit: usize) !Batch {
    const msg = try self.protocol.receiveMessage(); // Error → propagate up
    // No retry, no reconnect - simple error propagation
}
```

**Error Propagation Flow:**

```
PostgresStreamingSource.receiveBatch() (or PostgresPollingSource)
    ↓ (return error)
Processor.processChanges()
    ↓ (return error)
main.zig
    ↓ std.log.err("Failed to process changes: {}", .{err})
    ↓ std.process.exit(1)
Supervisor (systemd/k8s/docker)
    ↓ restart outboxx
Outboxx (new instance)
    ↓ connect, start from last confirmed LSN
PostgreSQL
    ↓ re-send changes from last LSN (no data loss)
```

**Post-MVP Considerations:**
- Dead letter queue for consistently unparseable messages
- Metrics/alerts for restart frequency (monitoring)
- Graceful shutdown on SIGTERM (cleanup resources)

---

## Components

### Common API (Both Sources)

**Simplified API without Transaction boundaries** - Processor only needs changes and LSN:

```zig
/// Batch of changes from PostgreSQL
pub const Batch = struct {
    /// Change events (flat list)
    changes: []ChangeEvent,

    /// LSN for feedback (last change in batch)
    last_lsn: u64,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Batch) void {
        for (self.changes) |*change| {
            change.deinit(self.allocator);
        }
        self.allocator.free(self.changes);
    }
};

/// Common methods (same signature for both sources)
pub fn init(allocator: std.mem.Allocator, config: Config) !Self;
pub fn receiveBatch(self: *Self, limit: usize) !Batch;
pub fn sendFeedback(self: *Self, lsn: u64) !void;
pub fn deinit(self: *Self) void;
```

**Why no Transaction type?**
- Processor doesn't care about transaction boundaries
- Polling source doesn't have transactions (text format limitation)
- Streaming source handles transactions internally (BEGIN/COMMIT)
- Simpler API, same functionality

### 1. PostgresStreamingSource

**Purpose:** High-level API for consuming WAL messages via streaming replication.

**Internal Structure:**
```zig
pub const PostgresStreamingSource = struct {
    allocator: std.mem.Allocator,
    protocol: ReplicationProtocol,
    decoder: PgOutputDecoder,
    registry: RelationRegistry,

    pub fn receiveBatch(self: *Self, limit: usize) !Batch {
        var changes = std.ArrayList(ChangeEvent).init(self.allocator);
        var current_txn: ?std.ArrayList(ChangeEvent) = null;
        var last_lsn: u64 = 0;

        // Collect changes until limit reached
        while (changes.items.len < limit) {
            const raw = try self.protocol.receiveMessage();
            last_lsn = raw.lsn;

            const msg = try self.decoder.decode(raw.data);

            switch (msg) {
                .begin => current_txn = std.ArrayList(ChangeEvent).init(self.allocator),
                .insert => |ins| {
                    const table = self.registry.getTableName(ins.relation_id) orelse return error.UnknownRelation;
                    const change = try self.toChangeEvent(ins, table);
                    try current_txn.?.append(change);
                },
                .commit => {
                    // Transaction complete → add to result
                    if (current_txn) |txn| {
                        try changes.appendSlice(txn.items);
                        txn.deinit();
                        current_txn = null;
                    }
                },
                .relation => |rel| try self.registry.register(rel.relation_id, rel.name),
            }
        }

        return .{
            .changes = try changes.toOwnedSlice(),
            .last_lsn = last_lsn,
            .allocator = self.allocator,
        };
    }

    pub fn sendFeedback(self: *Self, lsn: u64) !void {
        try self.protocol.sendStandbyStatusUpdate(lsn, lsn, lsn);
    }
};
```

**Responsibilities:**
- Orchestrate protocol, decoder, and registry
- Group messages into complete transactions internally (BEGIN → changes → COMMIT)
- Return flat list of changes to Processor
- Manage LSN tracking

### 1b. PostgresPollingSource

**Purpose:** Adapter wrapping old WalReader to match streaming API.

**Internal Structure:**
```zig
pub const PostgresPollingSource = struct {
    allocator: std.mem.Allocator,
    wal_reader: WalReader,
    wal_parser: WalParser,

    pub fn receiveBatch(self: *Self, limit: usize) !Batch {
        // Poll PostgreSQL
        const result = try self.wal_reader.peekChanges(limit);
        defer result.deinit(self.allocator);

        // Parse text to ChangeEvents
        var changes = std.ArrayList(ChangeEvent).init(self.allocator);
        for (result.events.items) |wal_event| {
            if (try self.wal_parser.parse(wal_event.data, "postgres")) |opt| {
                if (opt) |change| try changes.append(change);
            }
        }

        return .{
            .changes = try changes.toOwnedSlice(),
            .last_lsn = result.last_lsn orelse 0,
            .allocator = self.allocator,
        };
    }

    pub fn sendFeedback(self: *Self, lsn: u64) !void {
        try self.wal_reader.flushChanges(lsn);
    }
};
```

**Responsibilities:**
- Wrap old WalReader/WalParser
- Adapt to new API (receiveBatch, sendFeedback)
- Temporary - for benchmarking only

### 2. ReplicationProtocol

**Purpose:** Low-level PostgreSQL replication protocol implementation using libpq.

**Key Methods:**
```zig
pub const ReplicationProtocol = struct {
    allocator: std.mem.Allocator,
    connection: ?*c.PGconn,

    /// Connect with replication=database mode
    pub fn connect(self: *Self, conn_str: []const u8) !void;

    /// Send START_REPLICATION command
    pub fn startReplication(
        self: *Self,
        slot_name: []const u8,
        publication_name: []const u8,
        start_lsn: u64,
    ) !void;

    /// Receive one message from CopyBoth stream
    pub fn receiveMessage(self: *Self) !RawMessage;

    /// Send Standby Status Update (feedback)
    pub fn sendStandbyStatusUpdate(
        self: *Self,
        received_lsn: u64,
        flushed_lsn: u64,
        applied_lsn: u64,
    ) !void;
};

pub const RawMessage = struct {
    lsn: u64,
    data: []const u8,
};
```

**PostgreSQL Protocol Details:**

**START_REPLICATION command:**
```sql
START_REPLICATION SLOT slot_name LOGICAL 0/0
  (proto_version '2', publication_names 'pub_name', streaming 'off')
```

**Protocol Version Decision:**
- **v2 with streaming disabled** - Best balance for MVP
- Requires PostgreSQL 14+ (released Oct 2021)
- Same message types as v1 (no StreamStart/Stop/Commit/Abort)
- Improved decoding performance vs v1 (faster transaction processing, smaller slot size)
- No risk of StreamAbort (only committed transactions)
- Can enable `streaming 'on'` post-MVP for very large transactions (>1GB)

**Message Types (received):**
- `'w'` - XLogData (WAL data)
- `'k'` - Primary keepalive (heartbeat)

**Message Types (sent):**
- `'r'` - Standby Status Update (feedback)

**XLogData Format:**
```
Byte 0:       'w' (message type)
Bytes 1-8:    start LSN (big-endian u64)
Bytes 9-16:   end LSN (big-endian u64)
Bytes 17-24:  timestamp (big-endian i64)
Bytes 25+:    pgoutput binary data
```

**Standby Status Update Format:**
```
Byte 0:       'r' (message type)
Bytes 1-8:    received LSN (big-endian u64)
Bytes 9-16:   flushed LSN (big-endian u64)
Bytes 17-24:  applied LSN (big-endian u64)
Bytes 25-32:  timestamp (big-endian i64)
Byte 33:      reply requested (0 or 1)
```

### 3. PgOutputDecoder

**Purpose:** Decode pgoutput binary format into structured WalMessage types.

**Key Methods:**
```zig
pub const PgOutputDecoder = struct {
    allocator: std.mem.Allocator,

    /// Decode binary pgoutput message
    pub fn decode(self: *Self, data: []const u8) !WalMessage;

    // Private decoders for each message type
    fn decodeBegin(self: *Self, data: []const u8) !BeginMessage;
    fn decodeCommit(self: *Self, data: []const u8) !CommitMessage;
    fn decodeInsert(self: *Self, data: []const u8) !InsertMessage;
    fn decodeUpdate(self: *Self, data: []const u8) !UpdateMessage;
    fn decodeDelete(self: *Self, data: []const u8) !DeleteMessage;
    fn decodeRelation(self: *Self, data: []const u8) !RelationMessage;
};

pub const WalMessage = union(enum) {
    begin: BeginMessage,
    commit: CommitMessage,
    insert: InsertMessage,
    update: UpdateMessage,
    delete: DeleteMessage,
    relation: RelationMessage,
};
```

**PgOutput Binary Format (MVP subset):**

**BEGIN message (type 'B'):**
```
Byte 0:       'B'
Bytes 1-8:    final LSN (big-endian u64)
Bytes 9-16:   commit timestamp (big-endian i64)
Bytes 17-20:  transaction ID (big-endian u32)
```

**COMMIT message (type 'C'):**
```
Byte 0:       'C'
Bytes 1-8:    commit LSN (big-endian u64)
Bytes 9-16:   commit timestamp (big-endian i64)
```

**INSERT message (type 'I'):**
```
Byte 0:       'I'
Bytes 1-4:    relation ID (big-endian u32)
Byte 5:       tuple type ('N' for new)
Bytes 6-7:    number of columns (big-endian u16)
Bytes 8+:     column values (variable length)
```

**Column Value Format:**
```
Byte 0:       type ('n' = null, 't' = text, 'b' = binary)
Bytes 1-4:    length (big-endian u32) [only for 't' and 'b']
Bytes 5+:     value data [only for 't' and 'b']
```

**RELATION message (type 'R'):**
```
Byte 0:       'R'
Bytes 1-4:    relation ID (big-endian u32)
Bytes 5+:     namespace (null-terminated string)
Bytes X+:     relation name (null-terminated string)
Byte Y:       replica identity (1 byte)
Bytes Y+1-Y+2: number of columns (big-endian u16)
Bytes Y+3+:   column definitions (variable length)
```

**MVP Simplification:**
- Only decode relation_id, namespace, and name
- Skip replica identity details
- Skip column definitions (added post-MVP)

### 4. RelationRegistry

**Purpose:** Simple mapping from relation_id (u32) to table information.

**Key Methods:**
```zig
pub const RelationRegistry = struct {
    allocator: std.mem.Allocator,
    relations: std.AutoHashMap(u32, TableInfo),

    /// Register a relation
    pub fn register(
        self: *Self,
        relation_id: u32,
        table_name: []const u8,
    ) !void;

    /// Get table name by relation ID
    pub fn getTableName(self: *Self, relation_id: u32) ?[]const u8;
};

pub const TableInfo = struct {
    name: []const u8,
    // Future: schema, columns, types, etc.
};
```

**Why needed:**
- pgoutput uses `relation_id` (u32) in INSERT/UPDATE/DELETE messages
- Need to map `relation_id` → `table_name` for filtering
- PostgreSQL sends RELATION messages to establish this mapping

**Lifecycle Management:**

No persistence needed - registry rebuilds automatically:

```zig
// During normal operation:
// 1. RELATION message arrives → register(relation_id, table_name)
// 2. INSERT/UPDATE/DELETE → lookup relation_id in registry

// On application restart:
// 1. Registry starts empty
// 2. PostgreSQL re-sends RELATION messages before first use
// 3. Registry rebuilds automatically

// On ALTER TABLE:
// 1. PostgreSQL sends new RELATION message with updated schema
// 2. Registry updates mapping (overwrites old entry)

// On DROP TABLE:
// 1. No special handling needed
// 2. No more INSERT/UPDATE/DELETE messages for that relation_id
// 3. Registry entry becomes unused (can be cleaned up later)
```

**Key Insight:** PostgreSQL ALWAYS sends RELATION message before first use of relation_id in a session

---

## Implementation Plan

### Phase 1: Polling Source Adapter (Validate API Design)

**Step 1: Move existing code**
- [ ] Create `src/source/postgres_polling/` directory
- [ ] Move `src/source/postgres/wal_reader.zig` → `postgres_polling/wal_reader.zig`
- [ ] Move `src/source/postgres/wal_parser.zig` → `postgres_polling/wal_parser.zig`
- [ ] Verify old code still compiles (no changes yet)

**Step 2: Create polling source adapter**
- [ ] Create `postgres_polling/source.zig` with new API:
  - `pub const Batch = struct { changes: []ChangeEvent, last_lsn: u64 }`
  - `pub fn init(allocator, config) !PostgresPollingSource`
  - `pub fn receiveBatch(self, limit) !Batch`
  - `pub fn sendFeedback(self, lsn) !void`
  - `pub fn deinit(self) void`
- [ ] Implement adapter wrapping WalReader + WalParser
- [ ] Unit tests for adapter

**Step 3: Update Processor**
- [ ] Modify `src/processor/processor.zig` to use new API
- [ ] Replace old `peekChanges()` with `receiveBatch()`
- [ ] Update LSN feedback: `kafka.flush()` → `sendFeedback(lsn)`
- [ ] Remove dependency on old `wal_reader.zig` path

**Step 4: Validate with E2E tests**
- [ ] Run existing E2E tests - should pass without changes
- [ ] Verify no data loss (LSN feedback working correctly)
- [ ] Check memory usage (GPA leak detection)

**Checkpoint:** API validated with working code. Safe to proceed to streaming.

---

### Phase 2: Streaming Source Implementation

**Step 1: ReplicationProtocol (Low-level)**
- [ ] Create `postgres_streaming/replication_protocol.zig`
- [ ] Implement `connect()` with `replication=database` mode
- [ ] Implement `startReplication()` command:
  - `proto_version '2', streaming 'off', publication_names 'pub_name'`
- [ ] Implement `receiveMessage()` with XLogData parsing
- [ ] Implement `sendStandbyStatusUpdate()`
- [ ] Unit tests with mock binary data
- [ ] Integration test with real PostgreSQL (simple message flow)

**Step 2: PgOutputDecoder (Binary parser)**
- [ ] Create `postgres_streaming/pgoutput_decoder.zig`
- [ ] Implement `decode()` dispatcher (switch on message type byte)
- [ ] Implement `decodeBegin()` - parse transaction start
- [ ] Implement `decodeCommit()` - parse transaction end
- [ ] Implement `decodeInsert()` - parse INSERT with columns
- [ ] Implement `decodeRelation()` - parse relation_id + table name
- [ ] Unit tests with real pgoutput binary samples
- [ ] Integration tests (decode messages from real PostgreSQL)

**Step 3: RelationRegistry (Mapping)**
- [ ] Create `postgres_streaming/relation_registry.zig`
- [ ] Implement `AutoHashMap(u32, TableInfo)` wrapper
- [ ] Implement `register(relation_id, table_name)`
- [ ] Implement `getTableName(relation_id)`
- [ ] Unit tests (register, lookup, update)
- [ ] Memory leak tests (GPA)

**Step 4: PostgresStreamingSource (Orchestration)**
- [ ] Create `postgres_streaming/source.zig`
- [ ] Implement `init()` - connect + start replication
- [ ] Implement `receiveBatch(limit)`:
  - Receive messages until `changes.len >= limit`
  - Track current transaction (BEGIN → changes → COMMIT)
  - Resolve relation_id using registry
  - Return flat `Batch { changes, last_lsn }`
- [ ] Implement `sendFeedback(lsn)` - call `sendStandbyStatusUpdate()`
- [ ] Unit tests (mock protocol/decoder/registry)
- [ ] Integration tests with real PostgreSQL

**Step 5: Processor Integration**
- [ ] Add comptime switch in Processor to choose source type
- [ ] Test with streaming source
- [ ] Verify E2E tests pass (same tests, new source!)

**Checkpoint:** Streaming source working, same API as polling.

---

### Phase 3: Benchmarking & Cleanup

**Step 1: Performance benchmarks**
- [ ] Create benchmark suite:
  - 10,000 INSERT operations
  - Measure latency (PostgreSQL commit → Kafka send)
  - Measure CPU usage
  - Measure memory per event
- [ ] Run with polling source (baseline)
- [ ] Run with streaming source (comparison)
- [ ] Document results in benchmark report

**Step 2: Validate improvements**
- [ ] Verify latency improvement (<10ms vs 1s+)
- [ ] Verify CPU reduction (binary decode vs text parse)
- [ ] Verify memory efficiency
- [ ] Verify throughput improvement

**Step 3: Cleanup**
- [ ] Delete `src/source/postgres_polling/` directory
- [ ] Remove polling support from Processor
- [ ] Update configuration to use streaming by default
- [ ] Update CLAUDE.md with new architecture
- [ ] Update README if needed

**Step 4: Documentation**
- [ ] Add inline code documentation
- [ ] Update architecture diagrams
- [ ] Write migration guide (if needed for users)

---

### Timeline Estimate

- **Phase 1 (Polling Adapter):** 2-3 days
  - Low risk: wrapping existing working code
  - Validates API design before streaming work

- **Phase 2 (Streaming Implementation):** 1-2 weeks
  - Day 1-2: ReplicationProtocol + tests
  - Day 3-4: PgOutputDecoder + tests
  - Day 5: RelationRegistry + tests
  - Day 6-7: PostgresStreamingSource + integration

- **Phase 3 (Benchmarks + Cleanup):** 2-3 days
  - Benchmarks, validation, cleanup

**Total: ~2-3 weeks**

---

## Integration

### Processor Changes

**Old Code:**
```zig
// processor.zig - old approach
var result = try self.wal_reader.peekChanges(limit);
defer result.deinit(self.allocator);

if (result.events.items.len == 0) {
    return;
}

for (result.events.items) |wal_event| {
    // Parse text format: "table public.users: INSERT: ..."
    if (self.wal_parser.parse(wal_event.data, "postgres")) |change_event_opt| {
        if (change_event_opt) |domain_event| {
            // Process event
        }
    }
}

if (result.last_lsn) |last_lsn| {
    try self.flushAndCommit();
}
```

**New Code (Both sources use same API):**
```zig
// processor.zig - new approach (works with both polling and streaming)
const batch = try self.source.receiveBatch(1000); // limit: changes or transactions
defer batch.deinit();

if (batch.changes.len == 0) {
    return;
}

// Process each change
for (batch.changes) |change_event| {
    // Already parsed as ChangeEvent! No text parsing
    var matched_streams = try self.matchStreams(
        change_event.meta.resource,
        change_event.op
    );
    defer matched_streams.deinit(self.allocator);

    for (matched_streams.items) |stream_config| {
        const payload = try self.json_serializer.serialize(change_event);
        defer self.allocator.free(payload);

        try self.kafka_producer.send(
            stream_config.sink.destination,
            change_event.meta.resource, // partition key
            payload,
        );
    }
}

// CRITICAL: Kafka flush BEFORE LSN feedback
try self.kafka_producer.flush(); // Wait for acknowledgement
try self.source.sendFeedback(batch.last_lsn); // Confirm ONLY after Kafka
```

**Key Differences:**
1. ✅ **No text parsing** - Both sources return structured ChangeEvent
2. ✅ **Simple API** - Flat list of changes, no Transaction type
3. ✅ **Explicit feedback** - `sendFeedback()` instead of implicit advance
4. ✅ **Works with both sources** - Same code, different implementations
5. ✅ **Same flow** - matchStreams, serialize, send to Kafka (unchanged)

### Configuration Changes

**PostgreSQL Configuration:**
```conf
# postgresql.conf
wal_level = logical                    # Required (no change)
max_replication_slots = 10             # Required (no change)
max_wal_senders = 10                   # Required (no change)
```

**Publication Setup:**
```sql
-- Create publication (same as before)
CREATE PUBLICATION outboxx_pub FOR TABLE users, orders;
```

**Replication Slot:**
```sql
-- Create logical slot with pgoutput (instead of test_decoding)
SELECT pg_create_logical_replication_slot('outboxx_slot', 'pgoutput');
```

**Application Config:**
```toml
# config.toml - no changes required
[source.postgres]
host = "localhost"
port = 5432
database = "outboxx_test"
user = "postgres"
password_env = "POSTGRES_PASSWORD"
slot_name = "outboxx_slot"
publication_name = "outboxx_pub"
```

---

## References

### PostgreSQL Documentation
- [Logical Replication Protocol](https://www.postgresql.org/docs/current/protocol-replication.html)
- [pgoutput Plugin](https://www.postgresql.org/docs/current/logicaldecoding-output-plugin.html)
- [Streaming Replication Protocol](https://www.postgresql.org/docs/current/protocol-streaming.html)

### Similar Implementations
- [pglogrepl (Go)](https://github.com/jackc/pglogrepl) - Primary reference for protocol
- [Debezium PostgreSQL Connector](https://github.com/debezium/debezium/tree/main/debezium-connector-postgres) - Reference for features
- [pg_recvlogical](https://www.postgresql.org/docs/current/app-pgrecvlogical.html) - PostgreSQL built-in tool

### Binary Format References
- [pgoutput.c source code](https://github.com/postgres/postgres/blob/master/src/backend/replication/pgoutput/pgoutput.c)
- [Logical Decoding Output Plugin API](https://www.postgresql.org/docs/current/logicaldecoding-output-plugin.html)

### Zig Resources
- [Zig Standard Library](https://ziglang.org/documentation/master/std/)
- [Zig Network Programming](https://zig.guide/standard-library/networking)
- [Zig C Interop](https://ziglang.org/documentation/master/#C)

---

## Appendix A: Message Flow Example

### Complete Flow with LSN Feedback

```
PostgreSQL → Outboxx:
1. RELATION (relation_id=16384, name="users")
2. BEGIN (xid=1234, lsn=0/1000000)
3. INSERT (relation_id=16384, columns=[...])
4. INSERT (relation_id=16384, columns=[...])
5. COMMIT (xid=1234, lsn=0/1000100)

Outboxx Processing:
6. Parse messages → ChangeEvent[]
7. Send to Kafka → topic: "public.users"
8. Kafka flush → wait for acknowledgement ← CRITICAL!

Outboxx → PostgreSQL:
9. Standby Status Update (flushed_lsn=0/1000100) ← ONLY after Kafka flush

PostgreSQL:
10. Advance replication slot to 0/1000100 (can now reclaim WAL)
```

**Critical Ordering:**

```
✅ CORRECT (Both sources):
  batch = receiveBatch(limit)
  for (batch.changes) → kafka.send()
  kafka.flush()          ← MUST succeed!
  sendFeedback(batch.last_lsn)

❌ WRONG:
  batch = receiveBatch(limit)
  sendFeedback(batch.last_lsn)  ← Too early!
  for (batch.changes) → kafka.send()
  kafka.flush()          ← If fails, data loss!
```

**Processor doesn't see transactions:**
- Polling: Returns flat list (no transaction info in text format)
- Streaming: Returns flat list (transactions handled internally)
- Both: Same `Batch { changes: []ChangeEvent, last_lsn: u64 }`

## Appendix B: LSN Format

LSN (Log Sequence Number) format: `segment/offset`

**String format:** `"0/1A2B3C4D"` (hex)
**Binary format:** `u64 = 0x00000000_1A2B3C4D`

**Conversion functions:**
```zig
fn lsnToU64(lsn_str: []const u8) !u64 {
    // Parse "0/1A2B3C4D" -> 0x1A2B3C4D
}

fn u64ToLsn(allocator: std.mem.Allocator, lsn: u64) ![]const u8 {
    // Format 0x1A2B3C4D -> "0/1A2B3C4D"
}
```

## Appendix C: Performance Expectations

**Expected improvements:**

| Metric | Old (test_decoding) | New (pgoutput) | Improvement |
|--------|---------------------|----------------|-------------|
| Latency | 1000ms | <10ms | **100x** |
| CPU (parsing) | ~15% | ~2% | **7.5x** |
| Memory (per event) | ~500 bytes | ~100 bytes | **5x** |
| Throughput | ~10k events/s | ~50k events/s | **5x** |

**Benchmark methodology:**
- 10,000 INSERT events
- Single table with 10 columns
- Measure end-to-end latency from PostgreSQL commit to Kafka send

---

## Appendix D: Architecture Decisions Summary

This section summarizes key architectural decisions made during planning phase.

### 1. Protocol Version: v2 with Streaming Disabled

**Decision:** Use `proto_version '2', streaming 'off'`

**Rationale:**
- ✅ **Simple:** Same message types as v1 (BEGIN, COMMIT, INSERT, UPDATE, DELETE, RELATION)
- ✅ **Efficient:** v2 improvements (faster decoding, smaller slot size vs v1)
- ✅ **Safe:** Only committed transactions (no StreamAbort risk)
- ✅ **Modern:** PostgreSQL 14+ requirement acceptable for new projects (released Oct 2021)

**Comparison:**

| Approach | Protocol | Message Types | Large Txn Handling | Complexity |
|----------|----------|---------------|-------------------|------------|
| v1 | v1 | 5 types | Slow decoding | Simple |
| **v2 + streaming off** | v2 | 5 types | Fast decoding | Simple |
| v2 + streaming on | v2 | 9 types (+Stream*) | Real-time streaming | Complex |

**References:**
- Debezium uses v1 (for PostgreSQL <14 compatibility)
- pglogrepl demo uses v2 + streaming on (showcase all features)
- Outboxx uses v2 + streaming off (best balance for MVP)

### 2. Error Handling: Fail-Fast with Supervisor

**Decision:** No retry/reconnect logic in StreamingWalReader - fail-fast and rely on supervisor restart

**Rationale:**
- ✅ **Simple code:** No retry, backoff, or reconnect complexity
- ✅ **No data loss:** Replication slots preserve LSN across restarts
- ✅ **Production-ready:** Requires supervisor (systemd/k8s/docker) - documented in README

**Critical Guarantee:**
```
receiveBatch → sendToKafka → kafka.flush() → sendFeedback(LSN)
                                    ↑
                              MUST succeed before LSN confirm
```

### 3. LSN Feedback Timing: After Kafka Flush

**Decision:** Confirm LSN to PostgreSQL ONLY after Kafka flush succeeds

**Sequence:**
1. Receive batch from PostgreSQL
2. Send messages to Kafka
3. **Wait for Kafka flush acknowledgement** ← CRITICAL
4. Send LSN feedback to PostgreSQL ← Confirm only after Kafka

**Consequence:**
- If crash between (3) and (4): duplicate messages in Kafka (acceptable)
- If crash before (3): no duplicates, changes re-sent by PostgreSQL
- **No data loss in either case**

### 4. RelationRegistry: In-Memory, No Persistence

**Decision:** Don't persist relation registry to disk

**Rationale:**
- ✅ **Auto-rebuilds:** PostgreSQL always sends RELATION messages before first use
- ✅ **Simple:** No disk I/O, serialization, or recovery logic
- ✅ **Fast:** HashMap lookup in memory

**Lifecycle:**
- On start: empty registry
- On RELATION message: add/update entry
- On restart: PostgreSQL re-sends RELATION messages
- On ALTER TABLE: PostgreSQL sends updated RELATION message
- On DROP TABLE: no special handling (entry unused)

### 5. Two Separate Source Types (No Shared Code)

**Decision:** Implement as two completely independent source types

**Structure:**
```
src/source/
├── postgres_polling/    # Temporary (for benchmarks only)
└── postgres_streaming/  # Permanent (production)
```

**Rationale:**
- ✅ **Clean separation:** No dependencies between old and new code
- ✅ **Easy deletion:** After benchmarks, `rm -rf postgres_polling/`
- ✅ **No abstraction overhead:** No vtables, no interfaces
- ✅ **Same API via duck typing:** Comptime ensures compatibility

**Implementation approach:**
1. **Phase 1:** Create `postgres_polling/` with adapter wrapping old code
2. **Phase 2:** Validate API design with E2E tests
3. **Phase 3:** Implement `postgres_streaming/` with same API
4. **Phase 4:** Benchmarks → delete `postgres_polling/`

### 6. Simplified API (No Transaction Type)

**Decision:** Flat list of changes, no Transaction boundaries exposed

**API:**
```zig
pub const Batch = struct {
    changes: []ChangeEvent,  // Flat list
    last_lsn: u64,
};

pub fn receiveBatch(limit: usize) !Batch;
pub fn sendFeedback(lsn: u64) !void;
```

**Rationale:**
- ✅ **Processor doesn't care about transactions** - just needs changes
- ✅ **Polling can't provide transactions** - text format limitation
- ✅ **Streaming handles internally** - BEGIN/COMMIT invisible to consumer
- ✅ **Simpler is better** - fewer concepts, same functionality

**No changes to:**
- Domain layer (`ChangeEvent`, `Metadata`, `DataSection`)
- JSON serialization
- Kafka producer API
- Configuration format (except source type selection)

---

## Appendix E: Implementation Clarifications

This section contains answers to implementation questions discovered during planning and research.

### 1. Fast Table Filter (Streaming Source)

**Question:** Do we need Fast Table Filter for streaming source like in polling source?

**Answer:** ❌ **NO** - Not needed for streaming source.

**Rationale:**
- **Polling source:** `test_decoding` sends ALL tables from entire database → Fast filter critical (O(1) lookup skips expensive parsing)
- **Streaming source:** `pgoutput` + Publication already filters at PostgreSQL level → Only subscribed tables sent → Fast filter redundant

**Impact:**
- Remove fast filter from streaming source implementation
- Simpler code in `PostgresStreamingSource.receiveBatch()`
- No HashSet lookup needed - all received messages are relevant

### 2. Batch Limit Semantics

**Question:** What does `limit` parameter in `receiveBatch(limit)` mean exactly?

**Answer:** Desired batch size (soft limit), NOT strict boundary.

**Implementation:**
```zig
pub fn receiveBatch(self: *Self, limit: usize) !Batch {
    // Collect changes until approximately `limit` reached
    // - May return LESS if no more messages available
    // - May return MORE if transaction boundary requires it
    // - Don't split transactions across batches
}
```

**Examples:**
- `limit = 1000`, transaction has 500 changes → return 500 (less than limit)
- `limit = 1000`, transaction has 5000 changes → return 5000 (more than limit, don't split)
- `limit = 1000`, no messages in WAL → return 0 (empty batch)

**Rationale:**
- Soft limit provides better transaction integrity
- Avoids complex transaction splitting logic
- PostgreSQL can send large transactions atomically

### 3. Primary Keepalive Message Handling

**Question:** How to handle Primary Keepalive messages ('k') from PostgreSQL?

**Answer:** Parse and conditionally respond based on `ReplyRequested` flag.

**Message Format (based on pglogrepl):**
```
Byte 0:       'k' (message type)
Bytes 1-8:    ServerWALEnd (big-endian u64) - current WAL position
Bytes 9-16:   ServerTime (big-endian i64) - microseconds since Y2K
Byte 17:      ReplyRequested (0 or 1) - immediate response needed?
```

**Implementation in `ReplicationProtocol.receiveMessage()`:**
```zig
pub fn receiveMessage(self: *Self) !RawMessage {
    const msg_type = // read byte from CopyBoth stream

    if (msg_type == 'k') {
        // Parse keepalive
        const server_wal_end = readU64BigEndian(data[1..9]);
        const server_time = readI64BigEndian(data[9..17]);
        const reply_requested = data[17] != 0;

        std.log.debug("Primary keepalive: ServerWALEnd={}, ReplyRequested={}", .{server_wal_end, reply_requested});

        if (reply_requested) {
            // Send immediate feedback with current LSN position
            try self.sendStandbyStatusUpdate(
                self.last_received_lsn,
                self.last_received_lsn,
                self.last_received_lsn,
            );
        }

        // Keepalive is not a data message - recursively read next message
        return self.receiveMessage();
    }

    if (msg_type == 'w') {
        // Parse XLogData (actual WAL message)
        // ...
    }
}
```

**Why needed:**
- PostgreSQL uses keepalive to check connection health
- If client doesn't respond → connection timeout → disconnect
- Transparent to caller (`receiveBatch()` never sees keepalive)

**Reference:** [pglogrepl example](https://github.com/jackc/pglogrepl/blob/master/example/pglogrepl_demo/main.go)

### 4. UPDATE Message Format and REPLICA IDENTITY

**Question:** Does UPDATE message include old tuple values? How does REPLICA IDENTITY affect this?

**Answer:** UPDATE message format varies based on REPLICA IDENTITY setting.

**UPDATE Message Structure:**
```
Byte 0:       'U' (message type)
Bytes 1-4:    relation ID (big-endian u32)
Byte 5+:      Optional: 'K' (key tuple) OR 'O' (old tuple) OR neither
Byte X+:      'N' (new tuple) - always present
```

**REPLICA IDENTITY Options:**

| Setting | Old Data Sent | Message Contains | Use Case |
|---------|---------------|------------------|----------|
| **DEFAULT** | Primary key only | `'K'` tuple (key columns) | MVP - minimal overhead |
| **FULL** | All columns | `'O'` tuple (all old values) | Post-MVP - full history |
| **USING INDEX** | Index columns | `'K'` tuple (indexed columns) | Custom key selection |
| **NOTHING** | None | No 'K' or 'O' | No UPDATE/DELETE replication |

**MVP Implementation:**
- Assume REPLICA IDENTITY = DEFAULT (PostgreSQL default)
- Parse optional `'K'` tuple before `'N'` tuple
- Skip `'O'` tuple support (FULL mode) for MVP

**Decoder Logic:**
```zig
fn decodeUpdate(self: *Self, data: []const u8) !UpdateMessage {
    const relation_id = readU32BigEndian(data[1..5]);
    var offset: usize = 5;

    var key_tuple: ?TupleData = null;
    var old_tuple: ?TupleData = null;

    // Check for optional key/old tuple
    if (data[offset] == 'K') {
        offset += 1;
        key_tuple = try self.decodeTuple(data[offset..]);
        offset += // tuple size
    } else if (data[offset] == 'O') {
        offset += 1;
        old_tuple = try self.decodeTuple(data[offset..]);
        offset += // tuple size
    }

    // New tuple (always present)
    std.debug.assert(data[offset] == 'N');
    offset += 1;
    const new_tuple = try self.decodeTuple(data[offset..]);

    return UpdateMessage{
        .relation_id = relation_id,
        .key_tuple = key_tuple,      // MVP: for REPLICA IDENTITY DEFAULT
        .old_tuple = old_tuple,      // Post-MVP: for REPLICA IDENTITY FULL
        .new_tuple = new_tuple,
    };
}
```

**Reference:** [PostgreSQL Logical Replication Message Formats](https://www.postgresql.org/docs/current/protocol-logicalrep-message-formats.html)

### 5. LSN Format and Conversion

**Question:** When do we need to convert LSN between text and binary formats?

**Answer:** Depends on source type.

**LSN Formats:**
- **Text:** `"16/B374D848"` (two hex numbers separated by slash)
- **Binary:** `u64` (8 bytes, big-endian in protocol messages)

**Conversion Needs:**

| Component | Input Format | Output Format | Conversion Needed? |
|-----------|--------------|---------------|-------------------|
| **Polling Source** | Text (test_decoding) | u64 (internal) | ✅ Yes: `lsnToU64()` |
| **Streaming Source** | Binary (pgoutput) | u64 (internal) | ❌ No (already u64) |
| **Feedback Message** | u64 (internal) | Binary (protocol) | ❌ No (write as big-endian) |
| **Logging** | u64 (internal) | Text (display) | ✅ Yes: `u64ToLsn()` |

**Implementation:**
```zig
/// Parse text LSN "16/B374D848" -> 0x16B374D848
fn lsnToU64(lsn_str: []const u8) !u64 {
    // Split on '/'
    // Parse each part as hex
    // Combine: (high << 32) | low
}

/// Format binary LSN 0x16B374D848 -> "16/B374D848"
fn u64ToLsn(allocator: std.mem.Allocator, lsn: u64) ![]const u8 {
    const high = @truncate(u32, lsn >> 32);
    const low = @truncate(u32, lsn & 0xFFFFFFFF);
    return try std.fmt.allocPrint(allocator, "{X}/{X}", .{high, low});
}
```

**Reference:** [PostgreSQL pg_lsn Type](https://www.postgresql.org/docs/current/datatype-pg-lsn.html)

### 6. RELATION Message Timing

**Question:** When does PostgreSQL send RELATION messages?

**Answer:** "Before the first DML message for a given relation OID" in the session.

**Scenarios:**

**1. Initial Replication (START_REPLICATION from LSN):**
```
Client: START_REPLICATION SLOT slot_name LOGICAL 0/1000000 ...
Server: RELATION (relation_id=16384, name="users")      ← Before first use
Server: BEGIN
Server: INSERT (relation_id=16384, ...)                 ← Now we know 16384=users
```

**2. Application Restart:**
```
Registry: Empty (in-memory only)
PostgreSQL: Re-sends RELATION messages before first INSERT/UPDATE/DELETE
Registry: Rebuilds automatically
```

**3. ALTER TABLE (Schema Change):**
```
ALTER TABLE users ADD COLUMN email TEXT;
PostgreSQL: Sends new RELATION message with updated schema
Registry: Updates entry (overwrites old mapping)
```

**4. DROP TABLE:**
```
DROP TABLE users;
PostgreSQL: Stops sending messages for that relation_id
Registry: Entry becomes unused (no cleanup needed)
```

**Key Insight:** No persistence needed - PostgreSQL guarantees RELATION messages arrive before use.

**Reference:** [PostgreSQL Logical Replication Protocol](https://www.postgresql.org/docs/current/protocol-logical-replication.html)

### 7. Source Selection (Polling vs Streaming)

**Question:** How to choose between polling and streaming sources?

**Answer:** Configuration flag in `source.postgres` section.

**Configuration Example:**
```toml
[source.postgres]
engine = "streaming"  # Options: "polling" | "streaming"
host = "localhost"
port = 5432
slot_name = "outboxx_slot"
publication_name = "outboxx_pub"
```

**Implementation (Processor):**
```zig
// In processor initialization
const SourceType = switch (config.source.postgres.engine) {
    .polling => @import("postgres_polling").PostgresPollingSource,
    .streaming => @import("postgres_streaming").PostgresStreamingSource,
};

var source = try SourceType.init(allocator, config);
```

**Rationale:**
- Runtime configuration (not compile-time) allows easy benchmarking
- Same binary can test both implementations
- After benchmarks: remove polling support, default to streaming

### 8. Transaction Buffering Memory Limits

**Question:** Should we limit transaction buffer size in `receiveBatch()`?

**Answer:** ❌ **NO** - Let buffer grow, rely on Docker/system limits.

**Implementation:**
```zig
pub fn receiveBatch(self: *Self, limit: usize) !Batch {
    var changes = std.ArrayList(ChangeEvent).init(self.allocator);
    var current_txn: ?std.ArrayList(ChangeEvent) = null;

    // No hard limit on transaction size
    // If transaction is 100K changes → buffer all 100K
    // Memory limit enforced by:
    // - Docker container limits (--memory flag)
    // - Kubernetes resource limits
    // - OS OOM killer
}
```

**Rationale:**
- Production environment provides memory limits (Docker, k8s)
- Hard limits in code add complexity without benefit
- Large transactions are rare but must be handled atomically
- If OOM → process crash → supervisor restart → no data loss (LSN preserved)

**Example Docker Deployment:**
```yaml
services:
  outboxx:
    image: outboxx:latest
    deploy:
      resources:
        limits:
          memory: 2G  # System enforces limit
```

### 9. Graceful Shutdown

**Question:** How to handle graceful shutdown in MVP?

**Answer:** ✅ **Already implemented** in `Processor.shutdown()`.

**Existing Implementation (processor.zig:52-60):**
```zig
pub fn shutdown(self: *Self) void {
    std.log.debug("Shutting down processor...", .{});

    self.flushAndCommit() catch |err| {
        std.log.warn("Failed to flush and commit on shutdown: {}", .{err});
    };

    std.log.debug("Shutdown finished", .{});
}
```

**Error Handling During Processing:**
```zig
// On error during processing:
// 1. Do NOT commit LSN (batch.last_lsn NOT sent to PostgreSQL)
// 2. Propagate error up to main.zig
// 3. main.zig logs error and exits
// 4. Supervisor restarts process
// 5. PostgreSQL re-sends from last committed LSN
// Result: No data loss
```

**Shutdown Flow:**
```
SIGTERM received → main.zig
    ↓
Processor.shutdown()
    ↓
flushAndCommit() - send pending LSN feedback
    ↓
Clean exit (code 0)
    ↓
Supervisor: graceful shutdown, no restart
```

**Error Flow:**
```
Error during processing
    ↓
Propagate to main.zig
    ↓
std.log.err()
    ↓
exit(1) - NO LSN commit
    ↓
Supervisor: restart
    ↓
PostgreSQL: re-send from last LSN
```

### 10. Code Duplication (validator.zig)

**Question:** What to do with `validator.zig` when creating polling/streaming sources?

**Answer:** Duplicate into both directories (will be cleaned up later).

**Structure:**
```
src/source/
├── postgres_polling/         # Temporary (deleted after benchmarks)
│   ├── source.zig
│   ├── wal_reader.zig
│   ├── wal_parser.zig
│   └── validator.zig         # Duplicated (temporary)
│
└── postgres_streaming/       # Permanent
    ├── source.zig
    ├── replication_protocol.zig
    ├── pgoutput_decoder.zig
    ├── relation_registry.zig
    └── validator.zig         # Duplicated (permanent)
```

**Rationale:**
- No shared code between sources (clean separation)
- After benchmarks: `rm -rf postgres_polling/` removes duplicated validator
- Simple, no abstraction overhead

---

**End of Document**
