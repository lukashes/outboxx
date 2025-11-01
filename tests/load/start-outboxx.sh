#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting benchmark stack with Outboxx CDC..."
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

# Start Outboxx
echo "Starting Outboxx CDC..."
docker compose --profile outboxx up -d outboxx $@

echo "✅ Outboxx stack is running"
echo ""
echo "Grafana: http://localhost:3000 (admin/admin)"
echo "Prometheus: http://localhost:9090"
echo "cAdvisor: http://localhost:8080"
echo ""
echo "To run load tests:"
echo "  $SCRIPT_DIR/load/run-load.sh steady"
echo "  $SCRIPT_DIR/load/run-load.sh burst"
echo "  $SCRIPT_DIR/load/run-load.sh mixed"
echo "  $SCRIPT_DIR/load/run-load.sh ramp"
