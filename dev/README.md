# Outboxx Development Environment

**Purpose**: Working development environment for active Outboxx development.

This directory contains everything needed for contributing to Outboxx development. For architecture examples and design documentation, see `/docs/examples/`.

## Quick Start

### 1. Start Development Environment

```bash
# Start the dev stack (PostgreSQL + Kafka)
make env-up

# Status and logs
make env-status
make env-logs

# Stop the stack (env-down removes the data volumes)
make env-down
```

These targets wrap Docker Compose in this directory; run `docker-compose` here
directly if you need finer control, or `./run-dev.sh` for a scripted start.

### 2. Connect to Database

```bash
# Connect as main user
psql -h localhost -U postgres -d outboxx_test

# Or connect as CDC user
psql -h localhost -U outboxx_user -d outboxx_test
```

### 3. Test Logical Replication

After connecting to the database, execute:

```sql
-- 1. Create replication slot with pgoutput plugin
SELECT pg_create_logical_replication_slot('test_slot', 'pgoutput');

-- 2. Create publication for test tables
CREATE PUBLICATION test_pub FOR TABLE users, products;

-- 3. Verify slot was created
SELECT slot_name, plugin, slot_type, database, active
FROM pg_replication_slots;

-- 4. Make data changes
UPDATE users SET status = 'premium' WHERE id = 1;
INSERT INTO products (name, price, inventory_count, category)
VALUES ('Test Product', 99.99, 10, 'Test');

-- 5. Clean up when finished
DROP PUBLICATION test_pub;
SELECT pg_drop_replication_slot('test_slot');
```

**Note**: To read CDC events with pgoutput, use Outboxx or `pg_recvlogical` tool (binary protocol, not SQL queries).

## Data Structure

The database contains test tables:

- **users** - users (4 records)
- **products** - products (5 records)
- **orders** - orders (4 records)
- **order_items** - order items (8 records)
- **system_logs** - system logs (excluded from CDC)

## CDC Configuration Check

### Check PostgreSQL settings:

```sql
-- WAL level (should be 'logical')
SHOW wal_level;

-- Maximum number of WAL senders
SHOW max_wal_senders;

-- Maximum number of replication slots
SHOW max_replication_slots;

-- Publications for replication
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete
FROM pg_publication;

-- Tables in publication
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'outboxx_publication';
```

### Monitor activity:

```sql
-- Active connections
SELECT pid, usename, application_name, client_addr, state, query
FROM pg_stat_activity
WHERE application_name LIKE '%replication%' OR backend_type = 'walsender';

-- Replication statistics
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;

-- WAL statistics
SELECT * FROM pg_stat_wal;
```

## CDC Test Scenarios

### Scenario 1: Simple Changes

```sql
-- INSERT
INSERT INTO users (email, name) VALUES ('test@example.com', 'Test User');

-- UPDATE
UPDATE products SET price = price * 1.1 WHERE category = 'Electronics';

-- DELETE
DELETE FROM system_logs WHERE created_at < NOW() - INTERVAL '1 hour';
```

### Scenario 2: Bulk Changes

```sql
-- Bulk update
UPDATE products SET inventory_count = inventory_count + 10;

-- Batch insert
INSERT INTO orders (user_id, status, total_amount)
SELECT
    (RANDOM() * 3 + 1)::INTEGER as user_id,
    CASE WHEN RANDOM() < 0.5 THEN 'pending' ELSE 'processing' END as status,
    (RANDOM() * 1000 + 50)::DECIMAL(10,2) as total_amount
FROM generate_series(1, 5);
```

### Scenario 3: Transactional Changes

```sql
BEGIN;
    UPDATE users SET status = 'vip' WHERE id = 1;
    INSERT INTO orders (user_id, status, total_amount) VALUES (1, 'completed', 199.99);
    UPDATE products SET inventory_count = inventory_count - 1 WHERE id = 2;
COMMIT;
```

## Debugging and Troubleshooting

### Check PostgreSQL logs:

```bash
docker-compose logs postgres | grep -i error
docker-compose logs postgres | grep -i replication
```

### Restart environment:

```bash
# Restart, keeping data
make env-restart

# Full reload (deletes data!)
make env-down && make env-up
```

### Connect to container:

```bash
docker-compose exec postgres bash
```

## Cleanup

```bash
# Stop the stack and remove its data volumes
make env-down
```

## Run Outboxx against this stack

```bash
make run
```

`make run` builds Outboxx and runs it against `dev/config.toml`, defaulting
`POSTGRES_URL` to the local dev database. Point it elsewhere by overriding it:

```bash
POSTGRES_URL="postgres://user:pass@host:5432/db?sslmode=require" make run
```

Make changes in `psql` and watch the Kafka topics. Run the full suite with `make test`.
