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
- ✅ **PostgreSQL Integration**: Logical replication connectivity and slot management
- ✅ **WAL Change Detection**: INSERT, UPDATE, DELETE operations with test_decoding plugin
- ✅ **Message Processing**: WAL message parsing with JSON serialization
- ✅ **Kafka Integration**: Producer and Consumer implementation with librdkafka
- ✅ **Comprehensive Testing**: Integration tests with real PostgreSQL and Kafka
- ✅ **Development Environment**: Docker Compose setup with PostgreSQL and Kafka
- ✅ **Nix Environment**: Isolated, reproducible development environment with Zig 0.15.1
- ✅ **Dependency Management**: libpq and librdkafka ready via Nix

## Development Workflow

### Quick Start
```bash
# Enter isolated development environment (recommended)
make nix-shell
# OR: cd into project directory if direnv is installed (automatic)

# Start PostgreSQL development environment
make env-up

# Run all tests (unit + integration)
make test-all

# Development workflow (format + test + build)
make dev
```

### Common Commands
```bash
# Development environment setup
make nix-shell      # Enter Nix development environment
make help           # Show all available commands

# Build and test (inside Nix shell or with compatible system setup)
zig build                    # Build the project
zig build test              # Run unit tests
zig build test-integration  # Run integration tests

# Makefile convenience commands
make build          # Build the project
make test           # Run unit tests
make test-all       # Run all tests (starts PostgreSQL if needed)
make dev            # Development workflow (format + test + build)

# Development environment
make env-up         # Start PostgreSQL and Kafka with Docker Compose
make env-down       # Stop development environment

# Kafka debugging (use standard tools)
kafka-console-consumer --bootstrap-server localhost:9092 --topic public.users --from-beginning
kcat -C -b localhost:9092 -t public.users -f 'Topic: %t, Partition: %p, Offset: %o, Key: %k, Payload: %s\n'
```

## Architecture and Implementation Notes

### Current Architecture
The project follows a clean separation of concerns with distinct layers:

```
┌─────────────┐
│ PostgreSQL  │ (Source)
└──────┬──────┘
       │ WAL events
       ↓
┌─────────────────────┐
│ WAL Parser          │ src/source/postgres/
│ (PostgreSQL-specific)│
└──────┬──────────────┘
       │ Domain Model (ChangeEvent)
       ↓
┌─────────────────────┐
│ Domain Layer        │ src/domain/
│ (Pure Data Model)   │
└──────┬──────────────┘
       │ ChangeEvent
       ↓
┌─────────────────────┐
│ JSON Serializer     │ src/serialization/
│ (Format-specific)   │
└──────┬──────────────┘
       │ Binary JSON
       ↓
┌─────────────────────┐
│ CDC Processor       │ src/processor/
│ (Orchestration)     │
└──────┬──────────────┘
       │ (topic, key, payload)
       ↓
┌─────────────────────┐
│ Kafka Producer      │ src/kafka/
│ (Sink)              │
└──────┬──────────────┘
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
- **WalReader**: Connects to PostgreSQL logical replication, manages slots and publications
- **WalParser**: Parses PostgreSQL WAL messages into domain model
- **FieldParser**: Handles PostgreSQL-specific field type parsing
- Converts `test_decoding` output to `ChangeEvent`
- Independent from serialization format

#### Serialization Layer (`src/serialization/`)
- **JsonSerializer**: Converts domain model to JSON format
- Stateless, pure function approach
- Easy to add new formats (Avro, Protobuf) in the future

#### Flow Layer (`src/processor/`)
- **CdcProcessor**: Orchestrates the entire pipeline
- Manages WAL reader, parser, serializer, and Kafka producer
- Handles routing logic (topic, partition key)
- Multi-stream support with isolated replication slots

#### Sink Layer (`src/kafka/`)
- **KafkaProducer**: Minimal wrapper around librdkafka
- Accepts pre-serialized binary data
- High-performance message publishing

#### Infrastructure
- **Config Module** (`src/config/`): TOML-based configuration with validation
- **Integration Tests**: Comprehensive testing with real PostgreSQL and Kafka

### Testing Strategy
The project emphasizes robust testing:
- **Unit Tests**: For individual modules (config, WAL reader, WAL parser, JSON serializer, domain model)
- **Integration Tests**: Real PostgreSQL and Kafka with Docker Compose
- **Kafka Integration Tests**: Producer/consumer message flow validation
- **Memory Safety**: All tests verify proper cleanup with Zig allocators
- **Strict Testing**: Integration tests REQUIRE services to be running (no graceful skipping)

### Key Implementation Details
- Uses PostgreSQL logical replication with `test_decoding` plugin
- Requires `REPLICA IDENTITY FULL` for complete UPDATE/DELETE visibility
- WAL flushing (`pg_switch_wal()`) ensures reliable test execution
- Each test uses isolated replication slots to prevent interference
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
│   │   └── postgres/      # PostgreSQL-specific components
│   │       ├── wal_parser.zig      # WAL message parser (to domain model)
│   │       ├── wal_reader.zig      # WAL reader (logical replication)
│   │       └── wal_reader_test.zig # WAL reader unit tests
│   ├── serialization/     # Serialization layer
│   │   └── json.zig       # JSON serializer
│   ├── processor/         # Flow orchestration
│   │   └── cdc_processor.zig # CDC pipeline orchestrator
│   ├── kafka/             # Kafka sink adapter
│   │   ├── producer.zig      # Kafka producer
│   │   └── producer_test.zig # Kafka integration tests
│   ├── config/            # Configuration management
│   │   ├── config.zig     # TOML-based configuration
│   │   └── config_test.zig # Configuration tests
│   └── integration_test.zig # End-to-end integration tests
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
├── docker-compose.yml     # PostgreSQL and Kafka container setup
├── build.zig             # Zig build configuration
├── Makefile              # Development convenience commands
├── flake.nix             # Nix development environment
├── .envrc                # direnv configuration for auto-activation
└── CLAUDE.md             # This file - AI assistant guidelines
```

## Contributing Guidelines

### Code Style
- **Comments**: All code comments must be in English
- **Memory Management**: Use proper `defer` cleanup patterns with Zig allocators
- **Error Handling**: Leverage Zig's error unions for comprehensive error management
- **Testing**: Write both unit tests and integration tests for new functionality

### Development Process
1. Enter development environment: `make nix-shell` (or use direnv)
2. Start development environment: `make env-up` (PostgreSQL + Kafka)
3. Run tests to ensure baseline: `make test-all`
4. Implement changes following Zig idioms
5. Add/update tests for new functionality
6. Verify all tests pass: `make test-all`
7. Format code: `zig build fmt`

### Important Testing Notes
- **Unit Tests**: Run with `zig build test` - only test logic, no external services
- **Integration Tests**: Run with `zig build test-integration` - REQUIRE PostgreSQL and Kafka
- **Kafka Integration**: Tests will FAIL if Kafka is not running (no graceful skipping)
- **Memory Safety**: All tests use GPA with leak detection
- **Test Isolation**: Each integration test uses unique replication slots and topics

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

#### PostgreSQL Development
```bash
# Connect to development PostgreSQL
psql -h localhost -p 5432 -U postgres -d outboxx_test

# Check replication slots
SELECT * FROM pg_replication_slots;

# Manual WAL testing
SELECT pg_create_logical_replication_slot('manual_slot', 'test_decoding');
SELECT * FROM pg_logical_slot_get_changes('manual_slot', NULL, NULL);
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

