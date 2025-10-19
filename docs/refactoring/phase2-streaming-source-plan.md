# Phase 2: Streaming Source Implementation - Detailed Plan

**Status**: ✅ Complete (Tasks 1-4) | 🚧 Pending (Task 5 - Processor Integration)
**Date**: 2025-10-11
**Completed**: 2025-10-11
**Depends on**: [Phase 1 Complete](./phase1-polling-source-adapter.md)
**Reference**: [Streaming WAL Reader Plan](../streaming-wal-reader.md)

## Overview

Implement PostgreSQL streaming replication source using `pgoutput` plugin with binary protocol. This will replace polling-based CDC with real-time streaming for <10ms latency.

## Prerequisites (Phase 1 Complete)

- ✅ Polling source adapter validated
- ✅ Processor accepts source via dependency injection
- ✅ API proven: `receiveBatch()` / `sendFeedback()`
- ✅ All tests pass with polling source
- ✅ Memory safety validated

## Architecture Decisions (From Plan)

1. **Protocol**: v2 with `streaming 'off'` (PostgreSQL 14+)
2. **Error Handling**: Fail-fast, no retry logic
3. **Message Filtering**: pgoutput filters at PostgreSQL (no fast filter needed)
4. **Transaction Buffering**: No artificial limits (rely on system memory limits)
5. **Registry**: In-memory only, rebuilds on restart

## Implementation Strategy

**Iterative approach with validation at each step:**

1. Start with minimal protocol → test connection
2. Add message parsing → test single INSERT
3. Add transaction handling → test multi-row transactions
4. Add full decoder → test all operations
5. Integrate with processor → run E2E tests

## Phase 2 Tasks Breakdown

### Task 1: ReplicationProtocol Foundation (2-3 days)

**Goal**: Establish low-level streaming connection and message flow.

#### 1.1 Project Structure
```
src/source/postgres_streaming/
├── replication_protocol.zig     # Low-level libpq streaming protocol
├── replication_protocol_test.zig
└── test_fixtures/
    └── binary_samples.zig       # Sample pgoutput messages for tests
```

**Checklist**:
- [x] Create directory structure
- [x] Add module to build.zig
- [x] Define `RawMessage` and error types

#### 1.2 Connection & START_REPLICATION

**Implementation**:
```zig
pub const ReplicationProtocol = struct {
    allocator: std.mem.Allocator,
    connection: ?*c.PGconn,
    last_received_lsn: u64,

    pub fn connect(self: *Self, conn_str: []const u8) !void {
        // Connect with replication=database mode
    }

    pub fn createSlot(self: *Self, slot_name: []const u8) !void {
        // CREATE_REPLICATION_SLOT with pgoutput plugin
    }

    pub fn startReplication(
        self: *Self,
        slot_name: []const u8,
        publication_name: []const u8,
        start_lsn: u64,
    ) !void {
        // START_REPLICATION LOGICAL ...
        // (proto_version '2', publication_names 'pub', streaming 'off')
    }
};
```

**Tests**:
- [x] Unit: Connection string parsing
- [x] Integration: Connect to PostgreSQL with replication=database
- [x] Integration: Create slot with pgoutput plugin
- [x] Integration: START_REPLICATION command succeeds

**Validation**: ✅ Can establish streaming connection and enter CopyBoth mode.

#### 1.3 Message Receiving (XLogData + Keepalive)

**Implementation**:
```zig
pub const RawMessage = struct {
    lsn: u64,
    data: []const u8,
};

pub fn receiveMessage(self: *Self) !RawMessage {
    // PQgetCopyData() from CopyBoth stream
    // Parse message type: 'w' (XLogData) or 'k' (Keepalive)
    // Handle keepalive transparently (respond if requested)
    // Return XLogData to caller
}
```

**Keepalive Handling**:
```zig
// Inside receiveMessage():
if (msg_type == 'k') {
    const reply_requested = data[17] != 0;
    if (reply_requested) {
        try self.sendStandbyStatusUpdate(
            self.last_received_lsn,
            self.last_received_lsn,
            self.last_received_lsn,
        );
    }
    return self.receiveMessage(); // Recursive: get next message
}
```

**Tests**:
- [x] Unit: Parse XLogData format (LSN extraction)
- [x] Unit: Parse Keepalive format
- [x] Integration: Receive real XLogData from PostgreSQL
- [x] Integration: Respond to keepalive with reply_requested=1

**Validation**: ✅ Can receive and parse streaming messages.

#### 1.4 LSN Feedback

**Implementation**:
```zig
pub fn sendStandbyStatusUpdate(
    self: *Self,
    received_lsn: u64,
    flushed_lsn: u64,
    applied_lsn: u64,
) !void {
    // Format 'r' message with big-endian LSN values
    // PQputCopyData() to send feedback
}
```

**Tests**:
- [x] Unit: Format feedback message correctly
- [x] Integration: Send feedback, verify slot advances

**Validation**: ✅ LSN feedback works, replication slot advances.

**Checkpoint 1**: ✅ Protocol can connect, receive messages, send feedback.

---

### Task 2: PgOutputDecoder - Binary Parser (2-3 days)

**Goal**: Decode pgoutput binary format into structured messages.

#### 2.1 Message Type Dispatcher

**Implementation**:
```zig
pub const PgOutputDecoder = struct {
    allocator: std.mem.Allocator,

    pub fn decode(self: *Self, data: []const u8) !WalMessage {
        const msg_type = data[0];
        return switch (msg_type) {
            'B' => .{ .begin = try self.decodeBegin(data) },
            'C' => .{ .commit = try self.decodeCommit(data) },
            'R' => .{ .relation = try self.decodeRelation(data) },
            'I' => .{ .insert = try self.decodeInsert(data) },
            'U' => .{ .update = try self.decodeUpdate(data) },
            'D' => .{ .delete = try self.decodeDelete(data) },
            else => error.UnknownMessageType,
        };
    }
};

pub const WalMessage = union(enum) {
    begin: BeginMessage,
    commit: CommitMessage,
    relation: RelationMessage,
    insert: InsertMessage,
    update: UpdateMessage,
    delete: DeleteMessage,
};
```

**Tests**:
- [x] Unit: Dispatcher routes to correct decoder

**Validation**: ✅ Message type routing works.

#### 2.2 Transaction Messages (BEGIN/COMMIT)

**Implementation**:
```zig
pub const BeginMessage = struct {
    final_lsn: u64,
    commit_timestamp: i64,
    xid: u32,
};

fn decodeBegin(self: *Self, data: []const u8) !BeginMessage {
    // Parse bytes 1-8: LSN (big-endian u64)
    // Parse bytes 9-16: timestamp (big-endian i64)
    // Parse bytes 17-20: xid (big-endian u32)
}

pub const CommitMessage = struct {
    commit_lsn: u64,
    commit_timestamp: i64,
};

fn decodeCommit(self: *Self, data: []const u8) !CommitMessage {
    // Parse bytes 1-8: commit LSN
    // Parse bytes 9-16: timestamp
}
```

**Tests**:
- [x] Unit: Decode BEGIN with known binary input
- [x] Unit: Decode COMMIT with known binary input
- [x] Unit: Handle invalid input (too short, wrong type)

**Validation**: ✅ Transaction boundaries parsed correctly.

#### 2.3 RELATION Message

**Implementation**:
```zig
pub const RelationMessage = struct {
    relation_id: u32,
    namespace: []const u8,  // Schema
    name: []const u8,       // Table name
};

fn decodeRelation(self: *Self, data: []const u8) !RelationMessage {
    const relation_id = std.mem.readInt(u32, data[1..5], .big);

    // Parse null-terminated strings
    var offset: usize = 5;
    const namespace = std.mem.sliceTo(data[offset..], 0);
    offset += namespace.len + 1;
    const name = std.mem.sliceTo(data[offset..], 0);

    return .{
        .relation_id = relation_id,
        .namespace = try self.allocator.dupe(u8, namespace),
        .name = try self.allocator.dupe(u8, name),
    };
}
```

**Tests**:
- [x] Unit: Parse RELATION with namespace + name
- [x] Unit: Handle special characters in table names
- [x] Memory: Verify no leaks (GPA)

**Validation**: ✅ Relation metadata extracted correctly.

#### 2.4 INSERT Message

**Implementation**:
```zig
pub const InsertMessage = struct {
    relation_id: u32,
    tuple: TupleData,
};

pub const TupleData = struct {
    columns: []ColumnValue,
};

pub const ColumnValue = union(enum) {
    null,
    text: []const u8,
    // MVP: Only support text format ('t' type)
};

fn decodeInsert(self: *Self, data: []const u8) !InsertMessage {
    const relation_id = std.mem.readInt(u32, data[1..5], .big);

    // Byte 5: 'N' (new tuple)
    std.debug.assert(data[5] == 'N');

    const tuple = try self.decodeTuple(data[6..]);

    return .{
        .relation_id = relation_id,
        .tuple = tuple,
    };
}

fn decodeTuple(self: *Self, data: []const u8) !TupleData {
    const num_columns = std.mem.readInt(u16, data[0..2], .big);
    var columns = try self.allocator.alloc(ColumnValue, num_columns);

    var offset: usize = 2;
    for (columns) |*col| {
        const col_type = data[offset];
        offset += 1;

        col.* = switch (col_type) {
            'n' => .null,
            't' => blk: {
                const length = std.mem.readInt(u32, data[offset..][0..4], .big);
                offset += 4;
                const value = data[offset..][0..length];
                offset += length;
                break :blk .{ .text = try self.allocator.dupe(u8, value) };
            },
            else => return error.UnsupportedColumnType,
        };
    }

    return .{ .columns = columns };
}
```

**Tests**:
- [x] Unit: Parse INSERT with 1 column
- [x] Unit: Parse INSERT with multiple columns
- [x] Unit: Handle NULL values
- [x] Unit: Handle text values with special characters
- [x] Memory: Verify cleanup in errdefer paths

**Validation**: ✅ INSERT messages fully parsed.

#### 2.5 UPDATE Message (with REPLICA IDENTITY handling)

**Implementation**:
```zig
pub const UpdateMessage = struct {
    relation_id: u32,
    key_tuple: ?TupleData,  // REPLICA IDENTITY DEFAULT
    old_tuple: ?TupleData,  // REPLICA IDENTITY FULL (post-MVP)
    new_tuple: TupleData,
};

fn decodeUpdate(self: *Self, data: []const u8) !UpdateMessage {
    const relation_id = std.mem.readInt(u32, data[1..5], .big);
    var offset: usize = 5;

    var key_tuple: ?TupleData = null;
    var old_tuple: ?TupleData = null;

    // Optional key/old tuple
    if (data[offset] == 'K') {
        offset += 1;
        key_tuple = try self.decodeTuple(data[offset..]);
        offset += // calculated tuple size
    } else if (data[offset] == 'O') {
        offset += 1;
        old_tuple = try self.decodeTuple(data[offset..]);
        offset += // calculated tuple size
    }

    // New tuple (always present)
    std.debug.assert(data[offset] == 'N');
    offset += 1;
    const new_tuple = try self.decodeTuple(data[offset..]);

    return .{
        .relation_id = relation_id,
        .key_tuple = key_tuple,
        .old_tuple = old_tuple,
        .new_tuple = new_tuple,
    };
}
```

**Tests**:
- [x] Unit: UPDATE with key tuple only (DEFAULT)
- [x] Unit: UPDATE with old tuple (FULL)
- [x] Unit: UPDATE with no key/old tuple
- [x] Memory: Verify all tuples cleaned up

**Validation**: ✅ UPDATE messages parsed with all REPLICA IDENTITY modes.

#### 2.6 DELETE Message

**Implementation**:
```zig
pub const DeleteMessage = struct {
    relation_id: u32,
    key_tuple: ?TupleData,  // REPLICA IDENTITY DEFAULT
    old_tuple: ?TupleData,  // REPLICA IDENTITY FULL
};

fn decodeDelete(self: *Self, data: []const u8) !DeleteMessage {
    // Similar to UPDATE, but no 'N' tuple
}
```

**Tests**:
- [x] Unit: DELETE with key tuple
- [x] Unit: DELETE with old tuple
- [x] Memory: Cleanup verification

**Validation**: ✅ DELETE messages parsed correctly.

**Checkpoint 2**: ✅ All pgoutput message types decoded successfully.

---

### Task 3: RelationRegistry - Mapping (1 day)

**Goal**: Map relation_id (u32) to table information.

#### 3.1 Registry Implementation

**Implementation**:
```zig
pub const RelationRegistry = struct {
    allocator: std.mem.Allocator,
    relations: std.AutoHashMap(u32, TableInfo),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .relations = std.AutoHashMap(u32, TableInfo).init(allocator),
        };
    }

    pub fn register(
        self: *Self,
        relation_id: u32,
        namespace: []const u8,
        name: []const u8,
    ) !void {
        // Store owned copies
        const table_info = TableInfo{
            .namespace = try self.allocator.dupe(u8, namespace),
            .name = try self.allocator.dupe(u8, name),
        };

        // Overwrite if exists (ALTER TABLE case)
        if (self.relations.fetchPut(relation_id, table_info)) |old| {
            self.allocator.free(old.value.namespace);
            self.allocator.free(old.value.name);
        }
    }

    pub fn getTableName(self: *Self, relation_id: u32) ?[]const u8 {
        const info = self.relations.get(relation_id) orelse return null;
        return info.name;
    }

    pub fn getFullName(self: *Self, relation_id: u32) ?TableFullName {
        const info = self.relations.get(relation_id) orelse return null;
        return .{
            .schema = info.namespace,
            .table = info.name,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.relations.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.namespace);
            self.allocator.free(entry.value_ptr.name);
        }
        self.relations.deinit();
    }
};

pub const TableInfo = struct {
    namespace: []const u8,
    name: []const u8,
};

pub const TableFullName = struct {
    schema: []const u8,
    table: []const u8,
};
```

**Tests**:
- [x] Unit: Register single relation
- [x] Unit: Lookup existing relation
- [x] Unit: Lookup non-existent relation returns null
- [x] Unit: Update relation (ALTER TABLE simulation)
- [x] Unit: Multiple relations with same name, different schemas
- [x] Memory: No leaks on deinit (GPA)

**Validation**: ✅ Registry correctly maps relation_id to table names.

**Checkpoint 3**: ✅ Relation mapping works correctly.

---

### Task 4: PostgresStreamingSource - Orchestration (2-3 days)

**Goal**: Combine protocol, decoder, and registry into source adapter.

#### 4.1 Source Structure

**Implementation**:
```zig
pub const PostgresStreamingSource = struct {
    allocator: std.mem.Allocator,
    protocol: ReplicationProtocol,
    decoder: PgOutputDecoder,
    registry: RelationRegistry,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        var protocol = ReplicationProtocol.init(allocator);
        try protocol.connect(config.connection_string);
        try protocol.createSlot(config.slot_name);
        try protocol.startReplication(
            config.slot_name,
            config.publication_name,
            0, // Start from beginning (or last confirmed LSN)
        );

        return .{
            .allocator = allocator,
            .protocol = protocol,
            .decoder = PgOutputDecoder.init(allocator),
            .registry = RelationRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.protocol.deinit();
        self.decoder.deinit();
        self.registry.deinit();
    }
};
```

**Tests**:
- [x] Integration: Initialize source with real PostgreSQL
- [x] Integration: Verify CopyBoth mode established

**Validation**: ✅ Source initializes correctly.

#### 4.2 receiveBatch() - Core Logic

**Implementation**:
```zig
pub fn receiveBatch(self: *Self, limit: usize) !Batch {
    var changes = std.ArrayList(ChangeEvent).empty;
    var current_txn: ?std.ArrayList(ChangeEvent) = null;
    var last_lsn: u64 = 0;

    // Collect changes until limit reached
    while (changes.items.len < limit) {
        const raw = try self.protocol.receiveMessage();
        last_lsn = raw.lsn;

        const msg = try self.decoder.decode(raw.data);

        switch (msg) {
            .begin => {
                current_txn = std.ArrayList(ChangeEvent).empty;
            },

            .relation => |rel| {
                try self.registry.register(
                    rel.relation_id,
                    rel.namespace,
                    rel.name,
                );
            },

            .insert => |ins| {
                const full_name = self.registry.getFullName(ins.relation_id)
                    orelse return error.UnknownRelation;

                const change = try self.tupleToChangeEvent(
                    .INSERT,
                    full_name,
                    ins.tuple,
                    null, // No old data
                );

                try current_txn.?.append(self.allocator, change);
            },

            .update => |upd| {
                const full_name = self.registry.getFullName(upd.relation_id)
                    orelse return error.UnknownRelation;

                const change = try self.tupleToChangeEvent(
                    .UPDATE,
                    full_name,
                    upd.new_tuple,
                    upd.key_tuple orelse upd.old_tuple,
                );

                try current_txn.?.append(self.allocator, change);
            },

            .delete => |del| {
                const full_name = self.registry.getFullName(del.relation_id)
                    orelse return error.UnknownRelation;

                const change = try self.tupleToChangeEvent(
                    .DELETE,
                    full_name,
                    del.key_tuple orelse del.old_tuple.?,
                    null,
                );

                try current_txn.?.append(self.allocator, change);
            },

            .commit => {
                // Transaction complete - add to result
                if (current_txn) |txn| {
                    try changes.appendSlice(self.allocator, txn.items);
                    txn.deinit(self.allocator);
                    current_txn = null;
                }
            },
        }
    }

    return .{
        .changes = try changes.toOwnedSlice(self.allocator),
        .last_lsn = last_lsn,
        .allocator = self.allocator,
    };
}
```

**Helper Function**:
```zig
fn tupleToChangeEvent(
    self: *Self,
    operation: ChangeOperation,
    full_name: TableFullName,
    new_tuple: TupleData,
    old_tuple: ?TupleData,
) !ChangeEvent {
    // Convert TupleData (binary) -> RowData (domain model)
    // Map column values to field names (requires column metadata)
    // For MVP: Use ordinal positions (col0, col1, col2...)
    // Post-MVP: Use actual column names from RELATION message
}
```

**Tests**:
- [x] Integration: Receive batch with single INSERT
- [x] Integration: Receive batch with multi-row transaction
- [x] Integration: Handle multiple transactions in one batch
- [x] Integration: Unknown relation_id returns error
- [x] Memory: No leaks in transaction buffering

**Validation**: ✅ receiveBatch() returns correct ChangeEvent list.

#### 4.3 sendFeedback() - LSN Confirmation

**Implementation**:
```zig
pub fn sendFeedback(self: *Self, lsn: u64) !void {
    try self.protocol.sendStandbyStatusUpdate(lsn, lsn, lsn);
}
```

**Tests**:
- [x] Integration: Send feedback, verify slot advances
- [x] Integration: Feedback after Kafka flush (E2E)

**Validation**: ✅ LSN feedback correctly advances replication slot.

**Checkpoint 4**: ✅ Streaming source fully functional.

---

### Task 5: Processor Integration (1-2 days)

**Goal**: Switch Processor to use streaming source.

#### 5.1 Configuration Support

**Add to config.toml**:
```toml
[source.postgres]
engine = "streaming"  # "polling" | "streaming"
# ... existing config
```

**Update config.zig**:
```zig
pub const PostgresSource = struct {
    engine: SourceEngine,
    // ... existing fields
};

pub const SourceEngine = enum {
    polling,
    streaming,
};
```

**Tests**:
- [ ] Unit: Parse engine field from TOML
- [ ] Unit: Default to streaming if not specified

#### 5.2 Processor Factory Pattern

**Update main.zig**:
```zig
const SourceType = switch (config.source.postgres.engine) {
    .polling => @import("postgres_polling").PostgresPollingSource,
    .streaming => @import("postgres_streaming").PostgresStreamingSource,
};

var source = try SourceType.init(allocator, postgres_config);
defer source.deinit();

var processor = Processor.init(allocator, source, streams, kafka_config);
// ... rest unchanged
```

**Tests**:
- [ ] Integration: Processor with streaming source
- [ ] Integration: Switch between polling/streaming at runtime

#### 5.3 E2E Validation

**Run existing E2E tests with streaming source**:
- [ ] E2E: INSERT test passes
- [ ] E2E: UPDATE test passes
- [ ] E2E: DELETE test passes
- [ ] E2E: Multi-table test passes
- [ ] E2E: Message count validation (no loss/duplicates)

**Validation**: All E2E tests pass with streaming source (same as polling).

**Checkpoint 5**: Streaming source fully integrated with Processor.

---

## Testing Strategy

### Unit Tests
- Mock binary data for decoder tests
- No PostgreSQL dependency
- Fast feedback loop

### Integration Tests
- Real PostgreSQL with pgoutput plugin
- Test each component independently
- Verify protocol handshake, message parsing, registry

### E2E Tests
- Reuse existing tests from Phase 1
- Same black-box validation
- Compare polling vs streaming results

### Memory Safety
- GPA with leak detection on all tests
- Verify cleanup in error paths (errdefer)
- Stress test with large transactions

## Success Criteria

- [x] All unit tests pass
- [x] All integration tests pass
- [ ] All E2E tests pass (same as polling) - **Pending Task 5**
- [x] No memory leaks detected
- [ ] Latency < 10ms (vs 1s+ polling) - **Pending benchmarks**
- [ ] CPU usage lower than polling - **Pending benchmarks**
- [ ] Application runs without crashes for 1+ hour - **Pending long-term testing**

## Rollback Plan

If streaming source has critical issues:
1. Keep polling source in codebase (don't delete yet)
2. Default config to `engine = "polling"`
3. Fix streaming issues, re-test
4. Switch default to streaming when stable

## Timeline Estimate

- **Task 1 (Protocol)**: 2-3 days
- **Task 2 (Decoder)**: 2-3 days
- **Task 3 (Registry)**: 1 day
- **Task 4 (Source)**: 2-3 days
- **Task 5 (Integration)**: 1-2 days

**Total: 8-12 days** (~2 weeks)

## Next Steps After Phase 2

1. Performance benchmarking (Phase 3)
2. Compare polling vs streaming metrics
3. Decision: Keep or remove polling source
4. Update documentation
5. Production deployment

## Implementation Summary

**Date Completed**: 2025-10-11
**Status**: ✅ **Tasks 1-4 Complete** | 🚧 **Task 5 Pending (Next Phase)**

### What Was Implemented

**1. ReplicationProtocol (`replication_protocol.zig`)** - ✅ Complete
- Low-level PostgreSQL streaming replication protocol
- Connection with `replication=database` mode
- START_REPLICATION command with pgoutput plugin
- XLogData and Keepalive message parsing
- Standby Status Update (LSN feedback)
- All integration tests passing

**2. PgOutputDecoder (`pg_output_decoder.zig`)** - ✅ Complete
- Binary pgoutput format decoder
- Message type dispatcher (BEGIN, COMMIT, RELATION, INSERT, UPDATE, DELETE)
- Transaction boundaries handling
- Tuple data parsing with NULL support
- REPLICA IDENTITY support (DEFAULT and FULL modes)
- All unit tests passing

**3. RelationRegistry (`relation_registry.zig`)** - ✅ Complete
- relation_id → table name mapping
- In-memory HashMap-based registry
- Auto-rebuild on restart (PostgreSQL re-sends RELATION messages)
- ALTER TABLE support (overwrites old mapping)
- All unit tests passing with no memory leaks

**4. PostgresStreamingSource (`source.zig`)** - ✅ Complete
- High-level orchestrator coordinating protocol, decoder, and registry
- `receiveBatch(limit, timeout)` with batching logic
- `sendFeedback(lsn)` for LSN confirmation
- PgOutputMessage → ChangeEvent conversion
- TupleData → RowData conversion (all values as text for MVP)
- All integration tests passing (8/8 tests)

### Key Architectural Decisions Validated

1. **Protocol v2 with streaming='off'** - ✅ Works perfectly
   - Simple message types (no StreamStart/Stop/Abort)
   - Efficient decoding
   - Production-ready

2. **Fail-fast error handling** - ✅ Validated
   - No retry logic in WAL reader
   - Clean error propagation
   - Supervisor restart pattern ready

3. **In-memory relation registry** - ✅ Works as expected
   - Auto-rebuilds from RELATION messages
   - No persistence needed
   - Fast HashMap lookup

4. **Transaction buffering** - ✅ Implemented
   - No artificial limits
   - Collects complete transactions (BEGIN → changes → COMMIT)
   - Memory safety with proper cleanup

### Test Results

```
Build Summary: 8/8 tests passed
- postgres_streaming unit tests: ✅ Pass
- postgres_streaming integration tests: ✅ 7 passed (8s)
- kafka integration tests: ✅ 1 passed (21s)
- Memory safety: ✅ No leaks detected (GPA)
```

### Files Created

```
src/source/postgres_streaming/
├── source.zig                    # Main orchestrator (331 lines)
├── source_test.zig               # Unit tests
├── integration_test.zig          # Integration tests
├── replication_protocol.zig      # Low-level protocol (311 lines)
├── pg_output_decoder.zig         # Binary decoder (645 lines)
├── pg_output_decoder_test.zig    # Decoder unit tests
├── relation_registry.zig         # Relation mapping (118 lines)
└── relation_registry_test.zig    # Registry unit tests
```

### Zig 0.15.1 API Adaptations

Successfully adapted to new ArrayList API:
- `ArrayList.init()` → `ArrayList.empty`
- All methods now require explicit allocator parameter:
  - `.append(allocator, item)`
  - `.toOwnedSlice(allocator)`
  - `.deinit(allocator)`

### Next Steps

**Task 5: Processor Integration** (See Phase 3 plan)
- Add configuration support (`engine = "streaming"`)
- Update Processor to work with both polling and streaming sources
- Run E2E tests with streaming source
- Benchmark performance vs polling source
- Document results

**Performance Benchmarking** (Phase 3)
- Latency comparison (streaming vs polling)
- CPU usage comparison
- Memory usage comparison
- Throughput comparison

## References

- [Phase 1 Implementation](./phase1-polling-source-adapter.md)
- [Streaming WAL Reader Plan](../streaming-wal-reader.md)
- [PostgreSQL Logical Replication Protocol](https://www.postgresql.org/docs/current/protocol-replication.html)
- [pglogrepl Reference](https://github.com/jackc/pglogrepl)
