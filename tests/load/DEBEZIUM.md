# Debezium Configuration Notes

## Connector Configuration

The Debezium connector is configured to match Outboxx settings as closely as possible:

### Key Configuration Parameters

```json
{
  "plugin.name": "pgoutput",
  "publication.name": "outboxx_bench_pub",
  "slot.name": "debezium_bench_slot",
  "snapshot.mode": "never"
}
```

- **plugin.name**: `pgoutput` - PostgreSQL native logical replication protocol (faster than `decoderbufs`)
- **publication.name**: Uses the same publication as Outboxx (`outboxx_bench_pub`)
- **slot.name**: Separate replication slot to avoid conflicts with Outboxx
- **snapshot.mode**: `never` - Only capture changes (no initial snapshot), matching Outboxx behavior

### Message Format

```json
{
  "transforms": "unwrap",
  "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "transforms.unwrap.drop.tombstones": "false",
  "transforms.unwrap.delete.handling.mode": "rewrite",
  "transforms.unwrap.add.fields": "op,source.ts_ms,source.lsn"
}
```

- **ExtractNewRecordState**: Simplifies message structure (closer to Outboxx format)
- **add.fields**: Includes operation type, timestamp, and LSN in the message
- **JSON without schema**: Matches Outboxx JSON output

### Topic Naming

```json
{
  "topic.prefix": "outboxx",
  "database.server.name": "outboxx"
}
```

Topic name: `outboxx.public.bench_events` (matches Outboxx convention)

## Differences from Outboxx

### Message Structure

**Outboxx JSON:**
```json
{
  "op": "INSERT",
  "data": {
    "id": 1,
    "event_type": "user_signup",
    "event_timestamp": "2024-10-06T12:00:00",
    "user_id": 42
  },
  "meta": {
    "schema": "public",
    "resource": "bench_events",
    "timestamp": 1696593600000,
    "lsn": "0/12345678"
  }
}
```

**Debezium JSON (after ExtractNewRecordState):**
```json
{
  "id": 1,
  "event_type": "user_signup",
  "event_timestamp": "2024-10-06T12:00:00",
  "user_id": 42,
  "__op": "c",
  "__source_ts_ms": 1696593600000,
  "__lsn": 12345678
}
```

### Operation Types

| Operation | Outboxx | Debezium |
|-----------|---------|----------|
| INSERT    | `"INSERT"` | `"c"` (create) |
| UPDATE    | `"UPDATE"` | `"u"` (update) |
| DELETE    | `"DELETE"` | `"d"` (delete) |

## API Usage

### Check Connector Status
```bash
curl http://localhost:8083/connectors/bench-postgres-connector/status | jq
```

### Get Connector Configuration
```bash
curl http://localhost:8083/connectors/bench-postgres-connector | jq
```

### Update Connector Configuration
```bash
curl -X PUT -H "Content-Type: application/json" \
  --data @config/debezium-connector.json \
  http://localhost:8083/connectors/bench-postgres-connector/config
```

### Restart Connector
```bash
curl -X POST http://localhost:8083/connectors/bench-postgres-connector/restart
```

### Pause/Resume Connector
```bash
# Pause
curl -X PUT http://localhost:8083/connectors/bench-postgres-connector/pause

# Resume
curl -X PUT http://localhost:8083/connectors/bench-postgres-connector/resume
```

### Delete Connector
```bash
curl -X DELETE http://localhost:8083/connectors/bench-postgres-connector
```

## Performance Tuning

### Kafka Connect Settings

Increase throughput by editing `docker-compose.yml`:

```yaml
environment:
  # Batch size for producer
  CONNECT_PRODUCER_BATCH_SIZE: 16384
  CONNECT_PRODUCER_LINGER_MS: 10

  # Compression
  CONNECT_PRODUCER_COMPRESSION_TYPE: snappy

  # Task parallelism (default is 1)
  CONNECT_TASKS_MAX: 1
```

### Connector-Specific Tuning

Edit `config/debezium-connector.json`:

```json
{
  "max.batch.size": 2048,
  "max.queue.size": 8192,
  "poll.interval.ms": 100
}
```

## Monitoring

### Kafka Connect Metrics

JMX metrics available on port 9999 (not exposed by default).

To expose:
```yaml
environment:
  KAFKA_JMX_OPTS: "-Djava.rmi.server.hostname=localhost -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=9999 -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false"
```

### Key Metrics

- `kafka.connect:type=connector-metrics,connector=bench-postgres-connector`
- `kafka.connect:type=connector-task-metrics,connector=bench-postgres-connector`
- `debezium.postgres:type=connector-metrics,context=*`

## Troubleshooting

### Connector keeps restarting

Check logs:
```bash
docker logs bench_debezium | grep ERROR
```

Common issues:
- PostgreSQL connection (wrong credentials, wrong host)
- Publication doesn't exist
- Replication slot already in use

### No messages in Kafka

1. Check connector is running:
```bash
curl http://localhost:8083/connectors/bench-postgres-connector/status
```

2. Check tasks:
```bash
curl http://localhost:8083/connectors/bench-postgres-connector/tasks | jq
```

3. Verify replication slot:
```sql
SELECT * FROM pg_replication_slots WHERE slot_name = 'debezium_bench_slot';
```

### High memory usage

JVM by default allocates a lot of memory. To limit:

```yaml
environment:
  KAFKA_HEAP_OPTS: "-Xms256M -Xmx512M"
```

### Slow startup

Kafka Connect waits for:
1. Kafka brokers to be available
2. Internal topics to be created
3. Connector plugins to load

First startup can take 30-60 seconds.
