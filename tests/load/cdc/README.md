# CDC Plugin Specification

How to add new CDC solutions to the load testing framework.

## Overview

The load testing infrastructure uses a plugin-based architecture where each CDC solution is a self-contained module with:
- Docker container (Dockerfile)
- Configuration files
- Kafka topic naming convention

The core infrastructure (PostgreSQL, Kafka, monitoring) is shared across all CDC solutions.

## Quick Start: Adding a New CDC

### 1. Create CDC directory
```bash
mkdir -p cdc/<cdc-name>/
```

### 2. Create Dockerfile
```dockerfile
# cdc/<cdc-name>/Dockerfile
FROM <base-image>

# Install dependencies
# Configure CDC solution
# Set entrypoint
```

### 3. Create configuration
```bash
# cdc/<cdc-name>/config.<format>
# Configuration for your CDC solution
# Must connect to:
#   PostgreSQL: postgres:5432 (internal Docker network)
#   Kafka:      kafka:9092 (internal Docker network)
```

### 4. Update docker-compose.yml
```yaml
# Add service with profile
<cdc-name>:
  profiles: ["<cdc-name>"]
  build:
    context: cdc/<cdc-name>
    dockerfile: Dockerfile
  container_name: load_<cdc-name>
  depends_on:
    postgres:
      condition: service_healthy
    kafka:
      condition: service_healthy
  volumes:
    - ./cdc/<cdc-name>/config.*:/path/to/config
  mem_limit: 500m
  cpus: 1
  restart: unless-stopped
```

### 5. Update scripts/start.sh
Add CDC name to `SUPPORTED_CDC` array:
```bash
SUPPORTED_CDC=("outboxx" "debezium" "<cdc-name>")
```

If CDC requires initialization (like Debezium connector registration), add:
```bash
if [ "$CDC" = "<cdc-name>" ]; then
    echo "Initializing <cdc-name>..."
    # Initialization commands here
fi
```

### 6. Update scripts/switch.sh
Same as start.sh - add to `SUPPORTED_CDC` and initialization logic.

### 7. Test
```bash
make load-up CDC=<cdc-name>
make load-test-steady
make load-status
```

## Requirements

### 1. Docker Container
- Must connect to `postgres:5432` (PostgreSQL hostname in Docker network)
- Must connect to `kafka:9092` (Kafka hostname in Docker network)
- Must have health checks or startup readiness detection
- Resource limits: 500MB memory, 1 CPU core (configurable)

### 2. Kafka Topic Naming
Follow convention: `<cdc-name>.<schema>.<table>`

Examples:
- Outboxx: `outboxx.load_events`
- Debezium: `debezium.public.load_events`
- Your CDC: `<cdc-name>.load_events` or `<cdc-name>.public.load_events`

### 3. Message Format
The Kafka exporter expects JSON messages with:
- **Operation type**: Field containing "INSERT", "UPDATE", or "DELETE"
- **Event timestamp**: Field with event timestamp (for lag calculation)

The exporter automatically detects CDC solution from topic prefix and parses accordingly.

### 4. PostgreSQL Configuration
Use existing table: `public.load_events`
```sql
CREATE TABLE load_events (
    id SERIAL PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,
    event_timestamp TIMESTAMP NOT NULL,
    user_id INTEGER NOT NULL
);
```

Create replication slot and publication:
```sql
-- Use unique names to avoid conflicts
SELECT pg_create_logical_replication_slot('<cdc-name>_load_slot', 'pgoutput');
CREATE PUBLICATION <cdc-name>_load_pub FOR TABLE load_events;
```

## Existing Implementations

### Outboxx

**Structure:**
```
cdc/outboxx/
├── Dockerfile       # Multi-stage Nix build
└── config.toml      # TOML configuration
```

**Key points:**
- Native Zig binary
- Direct PostgreSQL streaming replication
- Topic: `outboxx.load_events`
- Metrics: `outboxx_*`

### Debezium

**Structure:**
```
cdc/debezium/
├── Dockerfile       # Based on debezium/connect
└── connector.json   # Kafka Connect connector config
```

**Key points:**
- JVM-based Kafka Connect
- Requires connector registration via REST API (handled in scripts/start.sh)
- Topic: `debezium.public.load_events`
- Metrics: `debezium_*`

## Metrics Integration

The Kafka exporter (`exporter/kafka_exporter.py`) automatically:
1. Detects CDC solution from Kafka topic prefix
2. Parses JSON messages
3. Exports Prometheus metrics with CDC-specific labels

**Metrics exported:**
- `<cdc>_events_total{operation="INSERT|UPDATE|DELETE"}` - event counter
- `<cdc>_replication_lag_seconds` - CDC lag (kafka_ts - event_ts)
- `<cdc>_last_event_timestamp` - timestamp of last processed event

To support new CDC, update `exporter/kafka_exporter.py`:
```python
# Add topic pattern
KAFKA_TOPICS = [
    'outboxx.bench_events',
    'debezium.public.bench_events',
    '<cdc-name>.<pattern>',  # Add your topic
]

# Add CDC detection
def detect_cdc_solution(topic):
    if 'outboxx' in topic:
        return 'outboxx'
    elif 'debezium' in topic:
        return 'debezium'
    elif '<cdc-name>' in topic:
        return '<cdc-name>'
```

## Grafana Dashboards

Grafana dashboards automatically show metrics for all CDC solutions if they follow naming convention:
- Variable: `$cdc` with values: `outboxx`, `debezium`, `<cdc-name>`
- Queries: `{cdc}_events_total`, `{cdc}_replication_lag_seconds`, etc.

## Testing Checklist

- [ ] CDC container starts successfully
- [ ] CDC connects to PostgreSQL and Kafka
- [ ] Load test produces events to Kafka
- [ ] Kafka exporter parses messages correctly
- [ ] Metrics appear in Grafana
- [ ] `make load-status` shows CDC as active
- [ ] `make load-switch` switches between CDC solutions

## Example: Adding Flink CDC

```bash
# 1. Create directory
mkdir -p cdc/flink/

# 2. Create Dockerfile
cat > cdc/flink/Dockerfile <<EOF
FROM flink:1.17-java11
# Install Flink CDC connector
RUN wget https://repo1.maven.org/maven2/com/ververica/flink-sql-connector-postgres-cdc/2.4.0/flink-sql-connector-postgres-cdc-2.4.0.jar \\
  -P /opt/flink/lib/
CMD ["standalone-job", "--job-classname", "com.example.FlinkCDC"]
EOF

# 3. Create config
cat > cdc/flink/config.yaml <<EOF
source:
  type: postgres
  hostname: postgres
  port: 5432
  database: outboxx_load
  table: load_events
sink:
  type: kafka
  bootstrap-servers: kafka:9092
  topic: flink.load_events
EOF

# 4. Update docker-compose.yml
# (add flink service with profile)

# 5. Update scripts
# (add "flink" to SUPPORTED_CDC)

# 6. Test
make load-up CDC=flink
make load-test-steady
```

## Troubleshooting

### CDC container won't start
- Check logs: `docker logs load_<cdc-name>`
- Verify PostgreSQL connection: `docker exec load_<cdc-name> psql -h postgres -U postgres -d outboxx_load`
- Verify Kafka connection: `docker exec load_<cdc-name> kafka-topics.sh --bootstrap-server kafka:9092 --list`

### No metrics in Grafana
- Check Kafka topic exists: `docker exec load_kafka kafka-topics.sh --bootstrap-server localhost:9092 --list`
- Check messages in topic: `docker exec load_kafka kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic <cdc-name>.load_events --from-beginning`
- Check exporter logs: `docker logs load_kafka_exporter`
- Update exporter to parse your message format

### High resource usage
- Adjust mem_limit and cpus in docker-compose.yml
- Tune CDC configuration for lower memory usage
- Check for memory leaks in CDC container

## Questions?

Open an issue or check existing implementations in `cdc/outboxx/` and `cdc/debezium/`.
