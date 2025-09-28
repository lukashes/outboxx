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
```
PostgreSQL WAL → WAL Reader → Message Processor → Kafka Producer → Kafka Topics
```

### Implemented Components
- **WAL Reader**: PostgreSQL logical replication using `test_decoding` plugin
- **Message Processor**: WAL message parsing, JSON serialization, topic/partition key generation
- **Kafka Producer**: High-performance message publishing with librdkafka
- **Test Consumer**: Simplified consumer integrated in tests for end-to-end validation
- **Config Module**: Database connection management with proper error handling
- **Integration Tests**: Comprehensive testing with real PostgreSQL and Kafka

### Testing Strategy
The project emphasizes robust testing:
- **Unit Tests**: For individual modules (config, WAL reader, message processor)
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
│   ├── main.zig           # Application entry point (placeholder)
│   ├── config.zig         # Configuration management
│   ├── config_test.zig    # Configuration unit tests
│   ├── integration_test.zig # Integration tests with PostgreSQL
│   ├── message_processor.zig # WAL message parsing and JSON serialization
│   ├── wal/               # WAL streaming components
│   │   ├── reader.zig     # WAL reader with logical replication
│   │   └── reader_test.zig # WAL reader unit tests
│   └── kafka/             # Kafka integration components
│       ├── producer.zig   # Kafka producer implementation
│       └── producer_test.zig # Kafka integration tests with embedded test consumer
├── dev/                   # Development environment
│   ├── config.toml        # Development configuration
│   ├── run-dev.sh         # Development startup script
│   ├── postgres/          # PostgreSQL configuration files
│   │   ├── postgres-init.sql  # Database schema and test data
│   │   ├── postgres.conf      # PostgreSQL configuration for CDC
│   │   └── pg_hba.conf        # PostgreSQL authentication config
│   └── README.md          # Development environment documentation
├── docs/                  # Documentation
│   └── examples/          # Configuration examples and architectural documentation
│       ├── config.toml    # Complete configuration example with design vision
│       └── README.md      # Examples documentation
├── docker-compose.yml     # PostgreSQL and Kafka container setup
├── build.zig             # Zig build configuration with Kafka targets
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

#### Message Processing Testing
```bash
# Test message processor unit tests
zig test src/message_processor.zig --library c --library pq

# Test individual components
zig test src/config_test.zig --library c --library pq
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

