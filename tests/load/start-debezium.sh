#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting benchmark stack with Debezium CDC..."
cd "$SCRIPT_DIR"

# Start infrastructure (PostgreSQL, Kafka, monitoring)
docker compose up -d postgres zookeeper kafka-1 kafka-2 kafka-3 prometheus cadvisor grafana kafka-exporter

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL..."
until docker exec load_postgres pg_isready -U postgres > /dev/null 2>&1; do
  sleep 1
done

# Wait for Kafka to be ready
echo "Waiting for Kafka..."
sleep 5

# Start Debezium Connect
echo "Starting Debezium Kafka Connect..."
docker compose --profile debezium up -d debezium

# Wait for Kafka Connect to be ready
echo "Waiting for Kafka Connect to be ready..."
until curl -s -o /dev/null -w "%{http_code}" http://localhost:8083/ | grep -q "200"; do
  sleep 2
done

# Register Debezium connector
echo "Registering Debezium PostgreSQL connector..."
curl -X POST -H "Content-Type: application/json" \
  --data @"$SCRIPT_DIR/config/debezium-connector.json" \
  http://localhost:8083/connectors

echo ""
echo "✅ Debezium stack is running"
echo ""
echo "Grafana: http://localhost:3000 (admin/admin)"
echo "Prometheus: http://localhost:9090"
echo "cAdvisor: http://localhost:8080"
echo "Kafka Connect: http://localhost:8083"
echo ""
echo "Check connector status:"
echo "  curl http://localhost:8083/connectors/load-postgres-connector/status | jq"
echo ""
echo "To run load tests:"
echo "  $SCRIPT_DIR/load/run-load.sh steady"
echo "  $SCRIPT_DIR/load/run-load.sh burst"
echo "  $SCRIPT_DIR/load/run-load.sh mixed"
echo "  $SCRIPT_DIR/load/run-load.sh ramp"
