#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Switching from Debezium to Outboxx..."

# Stop Debezium if running
if docker ps --format '{{.Names}}' | grep -q "load_debezium"; then
  echo "Stopping Debezium..."
  docker compose --profile debezium stop debezium
  docker compose --profile debezium rm -f debezium
fi

# Start Outboxx
echo "Starting Outboxx CDC..."
docker compose --profile outboxx up -d outboxx

# Wait a bit for Outboxx to start
sleep 3

echo ""
echo "✅ Switched to Outboxx"
echo ""
echo "Check Outboxx logs:"
echo "  docker logs load_outboxx"
echo ""
echo "⚠️  Note: Metrics exporter reads only NEW messages"
echo "Run a load test to see fresh metrics in Grafana:"
echo "  $SCRIPT_DIR/load/run-load.sh steady"
echo "  $SCRIPT_DIR/load/run-load.sh burst"
