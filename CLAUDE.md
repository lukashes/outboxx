# CLAUDE.md - AI Assistant Development Guidelines

This file provides guidance for AI assistants (like Claude Code) when working with the Outboxx codebase. It's also useful for contributors who want to understand the project's development philosophy and conventions.

## Project Overview

Outboxx is a lightweight PostgreSQL Change Data Capture (CDC) tool written in Zig that streams WAL changes to Apache Kafka. It aims to be a high-performance, resource-efficient alternative to JVM-based CDC solutions like Debezium.

## Development Philosophy

### Code Quality Standards
- **Memory Safety**: Use Zig allocators properly with `defer` cleanup patterns
- **Error Handling**: Leverage Zig's error unions for comprehensive error management
- **Testing**: Write both unit tests and integration tests for all functionality
- **Documentation**: All code comments should be in English
- **Idiomatic Zig**: Follow patterns from established Zig projects like [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle)
- **Performance Focus**: Minimize memory allocations and optimize for high throughput

### Current Implementation Status
- ✅ **PostgreSQL Streaming Replication**: Binary pgoutput protocol with real-time push
- ✅ **WAL Change Detection**: INSERT, UPDATE, DELETE operations via streaming protocol
- ✅ **Message Processing**: Binary message decoding with JSON serialization
- ✅ **Kafka Integration**: Producer implementation with at-least-once delivery
- ✅ **Comprehensive Testing**: Unit, integration, and E2E tests with real services
- ✅ **Development Environment**: Docker Compose setup with PostgreSQL and Kafka
- ✅ **Nix Environment**: Isolated, reproducible development environment with Zig 0.15.1
- ✅ **Production-Ready**: ~3.2k events/sec throughput, 3.73 MiB memory usage

## Development Workflow

### Environment Setup

This project uses **Nix** for reproducible builds and **direnv** (optional) for automatic environment activation.

**Smart Environment Loading:**
- Make commands auto-detect and use the appropriate Nix environment
- `.make-shell` wrapper uses priority: already in Nix > direnv (fast) > `nix develop` (fallback)
- No manual `nix develop` needed for make commands
- direnv is optional but recommended for faster iteration

### Quick Start
```bash
# Optional: Enable direnv for automatic environment (recommended for contributors)
direnv allow

# Start PostgreSQL development environment
make env-up

# Run all tests (unit + integration)
make test-all

# Development workflow (format + test + build)
make dev
```

### Common Commands
```bash
# Build and test (works everywhere - auto-loads Nix environment)
make build          # Build the project
make test           # Run unit tests
make test-integration # Run integration tests (requires PostgreSQL + Kafka)
make test-e2e       # Run E2E tests - full pipeline verification
make test-all       # Run all tests (starts PostgreSQL + Kafka if needed)
make dev            # Development workflow (format + test + build)

# Direct zig commands (require direnv or manual nix develop)
zig build                    # Build the project
zig build test              # Run unit tests
zig build test-integration  # Run integration tests
zig build test-e2e          # Run E2E tests

# Development environment
make env-up         # Start PostgreSQL and Kafka with Docker Compose
make env-down       # Stop development environment
make help           # Show all available commands

# Kafka debugging (use standard tools)
kafka-console-consumer --bootstrap-server localhost:9092 --topic public.users --from-beginning
kcat -C -b localhost:9092 -t public.users -f 'Topic: %t, Partition: %p, Offset: %o, Key: %k, Payload: %s\n'
```

**Note:** The `make nix-*` commands are primarily for CI/CD or when direnv is not available. Regular `make` commands work everywhere and are preferred.

## Architecture and Implementation Notes

### Current Architecture
The project follows a clean separation of concerns with distinct layers:

```
┌─────────────┐
│ PostgreSQL  │ (Source)
└──────┬──────┘
       │ Binary pgoutput stream (CopyBoth mode)
       ↓
┌──────────────────────────┐
│ ReplicationProtocol      │ src/source/postgres/
│ (Low-level libpq)        │
└──────┬───────────────────┘
       │ XLogData messages
       ↓
┌──────────────────────────┐
│ PgOutputDecoder          │ src/source/postgres/
│ (Binary format parser)   │
└──────┬───────────────────┘
       │ BEGIN/INSERT/COMMIT
       ↓
┌──────────────────────────┐
│ PostgresStreamingSource  │ src/source/postgres/
│ (Orchestrator)           │
└──────┬───────────────────┘
       │ Domain Model (ChangeEvent)
       ↓
┌──────────────────────────┐
│ Domain Layer             │ src/domain/
│ (Pure Data Model)        │
└──────┬───────────────────┘
       │ ChangeEvent
       ↓
┌──────────────────────────┐
│ JSON Serializer          │ src/serialization/
│ (Format-specific)        │
└──────┬───────────────────┘
       │ Binary JSON
       ↓
┌──────────────────────────┐
│ CDC Processor            │ src/processor/
│ (Orchestration)          │
└──────┬───────────────────┘
       │ (topic, key, payload)
       ↓
┌──────────────────────────┐
│ Kafka Producer           │ src/kafka/
│ (Sink)                   │
└──────┬───────────────────┘
       │
┌──────▼──────┐
│   Kafka     │ (Target)
└─────────────┘
```

### Implemented Components

#### Domain Layer (`src/domain/`)
- **ChangeEvent**: Pure domain model for CDC events
- **ChangeOperation**: INSERT, UPDATE, DELETE operations
- **Metadata**: Source metadata (schema, resource, timestamp, LSN)
- **DataSection**: Union type for operation-specific data
- No external dependencies, easily testable

#### Source Layer (`src/source/postgres/`)
- **PostgresStreamingSource**: Main orchestrator for streaming replication
- **ReplicationProtocol**: Low-level libpq streaming protocol (CopyBoth mode)
- **PgOutputDecoder**: Binary message parser (BEGIN, COMMIT, INSERT, UPDATE, DELETE, RELATION)
- **RelationRegistry**: Maps relation_id → table metadata (auto-rebuilds on restart)
- **Validator**: PostgreSQL configuration validation (wal_level, version checks)
- Binary protocol (pgoutput) for efficient decoding, no text parsing

#### Serialization Layer (`src/serialization/`)
- **JsonSerializer**: Converts domain model to JSON format
- Stateless, pure function approach
- Easy to add new formats (Avro, Protobuf) in the future

#### Flow Layer (`src/processor/`)
- **Processor**: Orchestrates the entire pipeline (generic over source type)
- Manages streaming source, serializer, and Kafka producer
- Handles routing logic (matchStreams: table → topic mapping)
- Multi-stream support with Publications for table filtering
- **At-least-once delivery**: Confirms LSN to PostgreSQL ONLY after Kafka flush succeeds
- **Fail-fast error handling**: Errors propagate to supervisor for restart

#### Sink Layer (`src/kafka/`)
- **KafkaProducer**: Minimal wrapper around librdkafka
- Accepts pre-serialized binary data
- High-performance message publishing

#### Infrastructure
- **Config Module** (`src/config/`): TOML-based configuration with validation
- **Integration Tests**: Comprehensive testing with real PostgreSQL and Kafka

### Testing Strategy

The project emphasizes robust testing at multiple levels:

#### Test Hierarchy

1. **Unit Tests** (`make test`)
   - Test individual modules in isolation (config, WAL parser, JSON serializer, domain model)
   - No external dependencies (PostgreSQL/Kafka)
   - Fast feedback loop for development
   - Examples: `src/config/config_test.zig`, `src/domain/change_event.zig`

2. **Integration Tests** (`make test-integration`)
   - Test components with real external services
   - Require PostgreSQL and Kafka running (Docker Compose)
   - Test individual adapters: WalReader, KafkaProducer
   - Examples: `src/source/postgres/wal_reader_test.zig`, `src/kafka/producer_test.zig`

3. **E2E Tests** (`make test-e2e`) - **Full Pipeline Verification**
   - **Black box testing**: Input (SQL) → Output (Kafka JSON)
   - **Critical verification**: N database changes = N Kafka messages (no duplicates/loss)
   - Test complete CDC flow: PostgreSQL → WAL → Parser → Serializer → Kafka
   - Validate JSON structure and content from Kafka topics
   - Examples: `tests/e2e/basic_cdc_test.zig`
   - **Location**: `tests/e2e/` directory (separate from `src/`)

#### Test Organization

**E2E Tests** - Separate directory:
- **Location**: `tests/e2e/` (top-level, outside `src/`)
- **Purpose**: Test complete system integration across all components
- **Helpers**: `tests/test_helpers.zig` provides shared utilities (Kafka consumer, JSON validation, SQL formatting)
- **Isolation**: E2E tests are isolated from unit/integration tests to avoid coupling
- **Example**: `tests/e2e/basic_cdc_test.zig` - INSERT/UPDATE/DELETE pipeline verification

**Unit and Integration Tests** - Colocated with modules:
- **Location**: Inside `src/` alongside the code they test
- **Convention**: `module_name_test.zig` in the same directory as `module_name.zig`
- **Purpose**: Test individual modules or components in isolation or with external dependencies
- **Examples**:
  - `src/config/config_test.zig` - Configuration parsing and validation (unit)
  - `src/kafka/producer_test.zig` - Kafka producer integration (integration)
  - `src/source/postgres/wal_reader_test.zig` - WAL reader integration (integration)
  - `src/processor/cdc_processor_test.zig` - Processor orchestration (unit/integration)

**Rationale**:
- **E2E separation**: E2E tests require different setup (full PostgreSQL + Kafka), test entire system, and change less frequently
- **Module colocation**: Unit/integration tests live with the code for easier maintenance and discoverability
- **Clear boundaries**: Developers know where to add tests based on what they're testing (module vs. full pipeline)

#### E2E Test Principles

E2E tests follow strict black-box principles:
- **What we test**: Full data pipeline from database changes to Kafka messages
- **What we verify**:
  - Message count matches change count (no duplicates, no message loss)
  - JSON structure is correct (`op`, `data`, `meta` fields)
  - Field values match expected data
  - Metadata is accurate (table name, schema, operation type)
- **What we DON'T check**: Internal state (LSN, flush status, processor internals)

Example E2E test flow:
```zig
// 1. Setup: Create unique table and topic
createTable("users_1234567890");
createStream("users_1234567890" -> "topic.users.1234567890");

// 2. Execute: Make database changes
INSERT INTO users_1234567890 VALUES ('Alice', 'alice@test.com');
INSERT INTO users_1234567890 VALUES ('Bob', 'bob@test.com');

// 3. Process: Run CDC pipeline
processor.processChangesToKafka();

// 4. Verify: Read ALL messages from Kafka and validate
messages = consumeAllMessages("topic.users.1234567890");
assert(messages.len == 2); // ✅ Exactly 2 messages
assert(messages[0].op == "INSERT"); // ✅ Correct operation
assert(messages[0].data.name == "Alice"); // ✅ Correct data
```

#### Test Execution

- **Memory Safety**: All tests verify proper cleanup with Zig allocators
- **Test Isolation**: Each integration/e2e test uses unique replication slots and topics
- **Strict Requirements**: Integration and E2E tests REQUIRE services running (no graceful skipping)
- **CI/CD Integration**: E2E tests run in GitHub Actions PR workflow with PostgreSQL + Kafka services

### Key Implementation Details

#### PostgreSQL Integration
- Uses PostgreSQL streaming replication with `pgoutput` plugin (binary protocol)
- **Publications filter at PostgreSQL level**: Only subscribed tables sent (efficient)
- Requires PostgreSQL 14+ for pgoutput protocol v2
- Requires `REPLICA IDENTITY FULL` for complete UPDATE/DELETE visibility
- WAL flushing (`pg_switch_wal()`) ensures reliable test execution
- Each test uses isolated replication slots and publications to prevent interference
- Auto-creates replication slot and publication on startup

#### Performance Optimizations
- **Binary protocol**: pgoutput eliminates text parsing overhead entirely
- **Event-driven I/O**: poll() syscall reduces CPU from 98% to <10%
- **Message batching**: Drain buffered messages after poll() wakeup for better throughput
- **LSN feedback timing**: Confirm to PostgreSQL ONLY after Kafka flush (at-least-once guarantee)
- **Relation registry**: In-memory HashMap, auto-rebuilds on restart (no disk I/O)

#### Message Format
- Kafka topics follow `schema.table` naming convention (e.g., `public.users`)
- Messages include operation type, table metadata, and timestamp
- JSON serialization for message payloads with proper memory management
- Producer uses automatic partition assignment with table-based partition keys

## Project Structure

```
├── src/                    # Main source code
│   ├── main.zig           # Application entry point
│   ├── domain/            # Domain layer (pure data model)
│   │   └── change_event.zig  # ChangeEvent, Metadata, DataSection
│   ├── source/            # Source adapters
│   │   └── postgres/      # PostgreSQL streaming replication
│   │       ├── source.zig              # Main orchestrator (PostgresStreamingSource)
│   │       ├── replication_protocol.zig # Low-level libpq protocol (CopyBoth mode)
│   │       ├── pg_output_decoder.zig   # Binary message parser
│   │       ├── relation_registry.zig   # Table metadata mapping
│   │       ├── validator.zig           # PostgreSQL configuration validator
│   │       ├── integration_test.zig    # Integration tests
│   │       └── *_test.zig              # Unit tests for each component
│   ├── serialization/     # Serialization layer
│   │   └── json.zig       # JSON serializer
│   ├── processor/         # Flow orchestration
│   │   ├── processor.zig  # CDC pipeline orchestrator (generic over source)
│   │   └── processor_test.zig # Processor tests (unit/integration)
│   ├── kafka/             # Kafka sink adapter
│   │   ├── producer.zig      # Kafka producer
│   │   └── producer_test.zig # Kafka integration tests
│   ├── config/            # Configuration management
│   │   ├── config.zig     # TOML-based configuration
│   │   └── config_test.zig # Configuration tests
├── tests/                 # E2E tests (separate from src/)
│   ├── test_helpers.zig   # Shared test utilities
│   │                      # - consumeAllMessages() - Kafka consumer helper
│   │                      # - assertJsonField() - JSON validation
│   │                      # - formatSqlZ() - SQL formatting helper
│   └── e2e/               # End-to-end pipeline tests
│       └── basic_cdc_test.zig # Full pipeline verification (INSERT/UPDATE/DELETE)
├── dev/                   # Development environment
│   ├── config.toml        # Development configuration
│   ├── run-dev.sh         # Development startup script
│   ├── postgres/          # PostgreSQL configuration files
│   │   ├── postgres-init.sql  # Database schema and test data
│   │   ├── postgres.conf      # PostgreSQL configuration for CDC
│   │   └── pg_hba.conf        # PostgreSQL authentication config
│   └── README.md          # Development environment documentation
├── docs/                  # Documentation
│   └── examples/          # Configuration examples
│       ├── config.toml    # Complete configuration example
│       └── README.md      # Examples documentation
├── .github/               # CI/CD workflows
│   └── workflows/
│       ├── ci.yml         # Build and unit tests
│       ├── pr-checks.yml  # Integration + E2E tests (with services)
│       └── security.yml   # Security scanning
├── docker-compose.yml     # PostgreSQL and Kafka container setup
├── build.zig             # Zig build configuration
├── Makefile              # Development convenience commands
├── flake.nix             # Nix development environment
├── .envrc                # direnv configuration for auto-activation
└── CLAUDE.md             # This file - AI assistant guidelines
```

**Note on Test Organization:**
- **E2E tests** live in `tests/e2e/` - separate from source code, test complete pipeline
- **Unit and Integration tests** live in `src/` - colocated with modules they test (e.g., `config.zig` + `config_test.zig`)
- **Convention**: Test files named `*_test.zig`, located in the same directory as the code they test
- **Rationale**: E2E tests require different infrastructure and change less frequently; module tests benefit from proximity to implementation

## Contributing Guidelines

### Code Style
- **Comments**: All code comments must be in English
- **Memory Management**: Use proper `defer` cleanup patterns with Zig allocators
- **Error Handling**: Leverage Zig's error unions for comprehensive error management
- **Testing**: Write both unit tests and integration tests for new functionality

### Logging Guidelines

Follow these principles to keep logs useful in both development and production:

#### Log Levels

- **`std.log.debug()`** - Development-only diagnostics
  - Detailed information useful during development and debugging
  - Should NOT clutter production output
  - Examples: "Parsing field X", "Connecting to endpoint Y", "Processing batch of N items"
  - Use liberally during development, these will be filtered out in production

- **`std.log.info()`** - Production-ready informational messages
  - Should be RARE and MEANINGFUL in production
  - Only log significant milestones or state changes
  - Examples: "CDC processor started", "Replication slot created", "Graceful shutdown initiated"
  - Rule of thumb: If it doesn't provide actionable insight in production, use `debug()` instead

- **`std.log.warn()`** - Error context when propagating errors upward
  - Use when a function returns an error and needs to log context
  - Provides diagnostic information while the error bubbles up
  - Examples: "Failed to connect to PostgreSQL (retrying...)", "Kafka message send failed for topic X"
  - The caller will decide if this becomes a fatal error

- **`std.log.err()`** - Fatal errors at the handler level ONLY
  - ONLY use when the error is **handled at this level** and cannot be propagated
  - Typically used in `main.zig` before `std.process.exit(1)`
  - Examples: "Failed to initialize CDC processor, exiting", "Configuration validation failed"
  - Rule: If you can return an error, return it instead of logging with `err()`

#### Examples

```zig
// ❌ BAD: Too verbose for production
pub fn processChanges() !void {
    std.log.info("Starting change processing", .{}); // This will spam production logs
    std.log.info("Reading from WAL", .{});
    std.log.info("Parsing message", .{});
}

// ✅ GOOD: Debug for development, info for milestones
pub fn processChanges() !void {
    std.log.debug("Starting change processing", .{}); // Debug: development only
    std.log.debug("Reading from WAL", .{});

    // Only log significant production events
    if (slot_created) {
        std.log.info("Replication slot 'outboxx_slot' created successfully", .{});
    }
}

// ❌ BAD: Using err() when error can be propagated
pub fn connectToKafka() !void {
    producer.init() catch |err| {
        std.log.err("Kafka connection failed: {}", .{err}); // Don't use err() here!
        return err;
    };
}

// ✅ GOOD: Using warn() when propagating error with context
pub fn connectToKafka(brokers: []const u8) !void {
    producer.init(brokers) catch |err| {
        std.log.warn("Kafka connection failed (brokers: {s}): {}", .{brokers, err});
        return err; // Propagate upward
    };
}

// ✅ GOOD: Using err() only at the top-level handler
pub fn main() !void {
    processor.initialize() catch |err| {
        std.log.err("Failed to initialize CDC processor: {}", .{err});
        std.process.exit(1); // Cannot propagate further
    };
}
```

#### Summary

- **Development**: Use `debug()` liberally for diagnostics
- **Production**: Use `info()` sparingly for significant events only
- **Error context**: Use `warn()` when propagating errors upward
- **Fatal errors**: Use `err()` only at top-level handlers (e.g., `main.zig`)

### stdout vs stderr in CLI Applications

CLI applications must use stdout and stderr correctly for proper Unix behavior:

#### When to Use Each Stream

- **stdout** - User-facing output and program results
  - Application startup messages ("Outboxx - PostgreSQL CDC")
  - Configuration summary ("Configuration loaded: ...")
  - Status updates ("Starting CDC processor...")
  - Command results and data output
  - Progress indicators for user

- **stderr** - Logging, diagnostics, and errors
  - All `std.log.*` output (debug, info, warn, err)
  - Error messages and warnings
  - Diagnostic information
  - Debug output

#### Why This Matters

```bash
# User wants to capture program output
outboxx --config config.toml > output.log

# ❌ WRONG: If using std.debug.print for status messages
#    output.log is EMPTY (everything went to stderr)

# ✅ CORRECT: If using stdout for status messages
#    output.log contains status, stderr shows logs
```

#### Implementation

**For user-facing messages in `main.zig`:**

```zig
// ❌ WRONG: std.debug.print writes to stderr
const print = std.debug.print;
print("Outboxx - PostgreSQL CDC\n", .{});

// ✅ CORRECT: Use stdout for user messages (Zig 0.15.1)
var buf: [4096]u8 = undefined;
const formatted = try std.fmt.bufPrint(&buf, "Outboxx - PostgreSQL CDC\n", .{});
const stdout_file = std.fs.File.stdout();
try stdout_file.writeAll(formatted);
```

**For logging (anywhere in codebase):**

```zig
// ✅ CORRECT: std.log.* writes to stderr (diagnostic info)
std.log.info("Processor initialized", .{});
std.log.warn("Connection retry...", .{});
std.log.err("Fatal error", .{});
```

**Simple wrapper for error handling (Zig 0.15.1):**

```zig
fn printStatus(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, fmt, args) catch |err| {
        std.log.warn("Failed to format message: {}", .{err});
        return;
    };
    const stdout_file = std.fs.File.stdout();
    stdout_file.writeAll(formatted) catch |err| {
        std.log.warn("Failed to write to stdout: {}", .{err});
    };
}

// Usage in main.zig:
printStatus("Configuration loaded: {s}\n", .{config_path});
```

#### Guidelines

1. **In `main.zig`**: Use `stdout` for all user-facing messages
2. **Everywhere else**: Use `std.log.*` for diagnostics (goes to stderr)
3. **Never use** `std.debug.print` for user messages (it writes to stderr)
4. **Test behavior**: Run `outboxx > out.log 2> err.log` to verify separation

This follows Unix philosophy: stdout for data, stderr for diagnostics.

### Development Process
2. Start development environment: `make env-up` (PostgreSQL + Kafka)
3. Run tests to ensure baseline: `make test-all`
4. Implement changes following Zig idioms
5. Add/update tests for new functionality
6. Verify all tests pass: `make test-all`
7. Format code: `zig build fmt`

### Important Testing Notes

- **Unit Tests**: Run with `make test` or `zig build test`
  - Only test logic, no external services required
  - Fast feedback loop for development

- **Integration Tests**: Run with `make test-integration` or `zig build test-integration`
  - REQUIRE PostgreSQL and Kafka running (use `make env-up`)
  - Test individual components with real services
  - Tests will FAIL if services are not available (no graceful skipping)

- **E2E Tests**: Run with `make test-e2e` or `zig build test-e2e`
  - REQUIRE PostgreSQL and Kafka running (use `make env-up`)
  - Test complete CDC pipeline from database to Kafka
  - Verify actual messages in Kafka topics
  - Black-box testing: only check input (SQL) and output (Kafka JSON)

- **Memory Safety**: All tests use GPA with leak detection
- **Test Isolation**: Each integration/e2e test uses unique replication slots and topics (timestamp-based names)
- **CI/CD**: All test levels run in GitHub Actions (unit in `ci.yml`, integration + e2e in `pr-checks.yml`)

### Development and Debugging Commands

#### Layer-Specific Testing
```bash
# Test domain layer (pure unit tests)
zig test --dep domain -Mroot=src/domain/change_event.zig

# Test serialization layer
zig test --dep domain -Mroot=src/serialization/json.zig -Mdomain=src/domain/change_event.zig

# Test PostgreSQL parser
zig test --dep domain -Mroot=src/source/postgres/wal_parser.zig -Mdomain=src/domain/change_event.zig

# Test individual components
zig test src/config/config_test.zig --library c --library pq
zig test src/wal/reader_test.zig --library c --library pq
```

#### Kafka Development
```bash
# Test Kafka integration (requires Kafka running)
zig build test-integration

# Run specific Kafka tests
zig test src/kafka/producer_test.zig --library c --library rdkafka

# Debug Kafka messages using standard tools
kafka-console-consumer --bootstrap-server localhost:9092 --topic public.users --from-beginning
```

#### E2E Testing
```bash
# Run all E2E tests (requires PostgreSQL + Kafka)
make test-e2e

# E2E tests verify complete pipeline
# - PostgreSQL changes → Kafka messages
# - Message count matches change count
# - JSON structure validation
# - No internal state checking (black box)

# Debug E2E test output
# Tests create unique topics like: topic.insert.1234567890
kafka-console-consumer --bootstrap-server localhost:9092 --topic topic.insert.1234567890 --from-beginning
```

#### PostgreSQL Development
```bash
# Connect to development PostgreSQL
psql -h localhost -p 5432 -U postgres -d outboxx_test

# Check replication slots
SELECT * FROM pg_replication_slots;

# Manual streaming replication testing
SELECT pg_create_logical_replication_slot('manual_slot', 'pgoutput');
CREATE PUBLICATION manual_pub FOR TABLE users;

# Use pg_recvlogical or Outboxx to read binary pgoutput messages
# (SQL queries don't work with pgoutput - binary protocol only)
```

## Architecture Benefits

### Separation of Concerns
- **Domain Layer**: Pure data structures, no dependencies on sources or formats
- **Source Adapters**: Parse source-specific formats into domain model
- **Serialization**: Convert domain model to target formats
- **Flow Orchestration**: Coordinate the pipeline without knowing implementation details

### Extensibility
- Easy to add new sources (MySQL, MongoDB) by creating new source adapters
- Easy to add new formats (Avro, Protobuf) by creating new serializers
- Easy to add new sinks (Pulsar, RabbitMQ) by creating new sink adapters

### Testability
- Each layer can be tested in isolation
- Domain model has no external dependencies
- Integration tests validate the full pipeline

