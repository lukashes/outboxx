# Outboxx - PostgreSQL Change Data Capture in Zig

Lightweight PostgreSQL CDC tool that streams WAL changes to Kafka. Built in Zig for minimal resource consumption.

**🚧 Development Status**: Early development phase - core WAL reader implemented, working toward complete CDC pipeline.

## What is Outboxx?

Outboxx captures PostgreSQL database changes in real-time and streams them to Kafka topics. Inspired by Debezium but designed for simplicity and low resource usage.

**Key Features:**
- PostgreSQL logical replication support ✅
- Multi-table CDC streams ✅
- Kafka producer integration ✅
- TOML-based configuration ✅
- Memory-safe Zig implementation ✅

## Current vs Planned

| Component | Status |
|-----------|--------|
| PostgreSQL WAL Reader | ✅ Working |
| Message Processing | ✅ Working |
| Kafka Producer | ✅ Working |
| TOML Configuration | ✅ Working |
| Multi-stream Support | ✅ Working |
| Schema Registry | 📋 Planned |
| Table/Column Filtering | 📋 Planned |
| Production Features | 📋 Planned |

## Inspired by Debezium

Outboxx is heavily inspired by [Debezium](https://debezium.io/), the industry standard for Change Data Capture. Debezium is an excellent, battle-tested solution with a rich feature set. However, being a JVM-based application, it comes with resource overhead that may not be suitable for all environments:

| Feature | Outboxx | Debezium |
|---------|---------|----------|
| **Runtime** | Native binary | JVM (Kafka Connect) |
| **Memory Usage** | ~10-50MB | ~200-500MB |
| **Startup Time** | <1s | 10-30s |
| **Configuration** | Simple TOML | Complex JSON/Properties |
| **Resource Usage** | Minimal overhead | JVM overhead |
| **Deployment** | Single binary | Kafka Connect cluster |

**Choose Outboxx when:**
- You love Debezium's approach but need lower resource usage
- Resource-constrained environments (edge computing, containers)
- Simple deployment scenarios without Kafka Connect infrastructure
- Zig/native performance is preferred over JVM ecosystem

**Stick with Debezium when:**
- You need its mature ecosystem and enterprise features
- Complex transformations and extensive connector library are required
- You already have Kafka Connect infrastructure
- Maximum feature coverage is more important than resource efficiency

Outboxx aims to bring Debezium's excellent CDC concepts to resource-constrained environments where every MB of RAM matters.

## Configuration Example

```toml
[metadata]
version = "v0"

[source]
type = "postgres"

[source.postgres]
host = "localhost"
port = 5432
database = "mydb"
user = "postgres"
password_env = "POSTGRES_PASSWORD"
slot_name = "outboxx_slot"
publication_name = "outboxx_publication"

[sink]
type = "kafka"

[sink.kafka]
brokers = ["localhost:9092"]

# Multiple streams for different tables
[[streams]]
name = "users-stream"

[streams.source]
resource = "users"
operations = ["insert", "update", "delete"]

[streams.flow]
format = "json"

[streams.sink]
destination = "user_changes"

[[streams]]
name = "orders-stream"

[streams.source]
resource = "orders"
operations = ["insert", "update"]

[streams.flow]
format = "json"

[streams.sink]
destination = "order_changes"
```

For complete configuration examples and architectural documentation, see [`docs/examples/config.toml`](docs/examples/config.toml).

## Quick Start

### Development Setup

```bash
# Enter development environment (recommended)
make nix-shell

# Start PostgreSQL and Kafka services
make env-up

# Set database password
export POSTGRES_PASSWORD="password"

# Run the application with development config
zig build run -- --config dev/config.toml
```

For complete development setup instructions, see [`dev/README.md`](dev/README.md).

## Contributing

This is a learning project for Zig programming. See [`dev/README.md`](dev/README.md) for development setup.

### Architecture Documentation

For complete configuration examples and design vision, see [`docs/examples/`](docs/examples/).

## License

MIT License - See LICENSE file for details.