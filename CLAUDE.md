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
- ✅ **Comprehensive Testing**: Integration tests with real PostgreSQL database
- ✅ **Development Environment**: Docker Compose setup with automated testing

## Development Workflow

### Quick Start
```bash
# Start PostgreSQL development environment
make env-up

# Run all tests (unit + integration)
make test-all

# Development workflow (format + test + build)
make dev
```

### Common Commands
```bash
# Build and test
zig build                    # Build the project
zig build test              # Run unit tests
zig build test-integration  # Run integration tests

# Running specific integration tests
zig test src/integration_test.zig --library c --library pq -I/usr/include/postgresql --test-filter "INSERT"
zig test src/integration_test.zig --library c --library pq -I/usr/include/postgresql --test-filter "UPDATE"
zig test src/integration_test.zig --library c --library pq -I/usr/include/postgresql --test-filter "DELETE"

# Development environment
make env-up         # Start PostgreSQL with Docker Compose
make env-down       # Stop PostgreSQL environment
make help           # Show all available commands
```

## Architecture and Implementation Notes

### Current Architecture
```
PostgreSQL WAL → WAL Reader → (Future: Message Processor → Kafka Producer)
```

### Implemented Components
- **WAL Reader**: PostgreSQL logical replication using `test_decoding` plugin
- **Config Module**: Database connection management with proper error handling
- **Integration Tests**: Comprehensive testing with real PostgreSQL database

### Testing Strategy
The project emphasizes robust testing:
- **Unit Tests**: For individual modules (config, WAL reader)
- **Integration Tests**: Real PostgreSQL database with Docker Compose
- **Memory Safety**: All tests verify proper cleanup with Zig allocators

### Key Implementation Details
- Uses PostgreSQL logical replication with `test_decoding` plugin
- Requires `REPLICA IDENTITY FULL` for complete UPDATE/DELETE visibility
- WAL flushing (`pg_switch_wal()`) ensures reliable test execution
- Each test uses isolated replication slots to prevent interference

## Project Structure

```
├── src/                    # Main source code
│   ├── main.zig           # Application entry point (placeholder)
│   ├── config.zig         # Configuration management
│   ├── config_test.zig    # Configuration unit tests
│   ├── integration_test.zig # Integration tests with PostgreSQL
│   └── wal/               # WAL streaming components
│       ├── reader.zig     # WAL reader with logical replication
│       └── reader_test.zig # WAL reader unit tests
├── dev/                   # Development environment
│   ├── postgres-init.sql  # Database schema and test data
│   └── docker-compose.yml # PostgreSQL container setup
├── build.zig             # Zig build configuration
├── Makefile              # Development convenience commands
└── CLAUDE.md             # This file - AI assistant guidelines
```

## Contributing Guidelines

### Code Style
- **Comments**: All code comments must be in English
- **Memory Management**: Use proper `defer` cleanup patterns with Zig allocators
- **Error Handling**: Leverage Zig's error unions for comprehensive error management
- **Testing**: Write both unit tests and integration tests for new functionality

### Development Process
1. Start PostgreSQL environment: `make env-up`
2. Run tests to ensure baseline: `make test-all`
3. Implement changes following Zig idioms
4. Add/update tests for new functionality
5. Verify all tests pass: `make test-all`
6. Format code: `zig build fmt`

