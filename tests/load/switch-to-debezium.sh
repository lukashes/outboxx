#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Switching from Outboxx to Debezium..."

# Stop Outboxx if running
if docker ps --format '{{.Names}}' | grep -q "load_outboxx"; then
  echo "Stopping Outboxx..."
  docker compose --profile outboxx stop outboxx
  docker compose --profile outboxx rm -f outboxx
fi

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
  http://localhost:8083/connectors 2>/dev/null || echo "Connector already exists"

echo ""
echo "✅ Switched to Debezium"
echo ""
echo "Check connector status:"
echo "  curl http://localhost:8083/connectors/load-postgres-connector/status | jq"
echo ""
echo "⚠️  Note: Metrics exporter reads only NEW messages"
echo "Run a load test to see fresh metrics in Grafana:"
echo "  $SCRIPT_DIR/load/run-load.sh steady"
echo "  $SCRIPT_DIR/load/run-load.sh burst"
