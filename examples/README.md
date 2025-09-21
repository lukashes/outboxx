# ZiCDC Examples

This directory contains example configurations and setup files for ZiCDC development and testing.

## Files Overview

### Configuration
- **`config.yaml`** - Complete configuration example with all available options
- **`config.minimal.yaml`** - Minimal configuration for quick setup

### Development Environment
- **`docker-compose.dev.yml`** - Complete development stack (PostgreSQL + Kafka)
- **`postgres-init.sql`** - Database initialization with sample data

## Quick Start

### 1. Start Development Environment

```bash
# Start PostgreSQL and Kafka
cd examples
docker-compose -f docker-compose.dev.yml up -d

# Wait for services to be ready (about 30 seconds)
docker-compose -f docker-compose.dev.yml logs -f
```

### 2. Verify Setup

```bash
# Check PostgreSQL
psql -h localhost -U postgres -d myapp -c "SELECT * FROM users;"

# Check Kafka topics (after running ZiCDC)
docker exec -it zicdc-kafka kafka-topics --bootstrap-server localhost:9092 --list
```

### 3. Run ZiCDC

```bash
# From project root
make build
./zig-out/bin/zicdc --config examples/config.yaml
```

## Configuration Options

The example configuration includes:

- **Source**: PostgreSQL connection and replication settings
- **Target**: Kafka brokers and topic configuration
- **Filtering**: Table and column inclusion/exclusion rules
- **Performance**: Buffer sizes, batch settings, memory limits
- **Monitoring**: Metrics and health check endpoints
- **Logging**: Output format and rotation settings
- **State Management**: Checkpoint and recovery configuration

## Development Workflow

1. **Make Changes**: Modify tables in PostgreSQL
2. **Observe**: Check Kafka topics for CDC messages
3. **Monitor**: Use Kafka UI at http://localhost:8080
4. **Debug**: Check ZiCDC logs and metrics

## Sample Data

The PostgreSQL initialization includes:
- `users` table with 3 sample users
- `products` table with 4 sample products
- `orders` and `order_items` tables with sample orders
- `audit_logs` table (excluded from CDC)

## Testing CDC

Try these commands to generate change events:

```sql
-- Insert new user
INSERT INTO users (email, name, password_hash)
VALUES ('test@example.com', 'Test User', '$2a$12$test_hash');

-- Update product inventory
UPDATE products SET inventory_count = inventory_count - 1 WHERE id = 1;

-- Create new order
INSERT INTO orders (user_id, status, total_amount)
VALUES (1, 'pending', 29.99);

-- Delete old audit logs (should not appear in CDC)
DELETE FROM audit_logs WHERE changed_at < NOW() - INTERVAL '30 days';
```

## Cleanup

```bash
# Stop and remove containers
docker-compose -f docker-compose.dev.yml down -v

# Remove volumes (careful: this deletes all data)
docker volume prune
```