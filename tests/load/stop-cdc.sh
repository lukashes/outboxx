#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Stopping CDC services..."

# Stop Outboxx if running
if docker ps --format '{{.Names}}' | grep -q "load_outboxx"; then
  echo "Stopping Outboxx..."
  docker compose --profile outboxx stop outboxx
  docker compose --profile outboxx rm -f outboxx
fi

# Stop Debezium if running
if docker ps --format '{{.Names}}' | grep -q "load_debezium"; then
  echo "Stopping Debezium..."
  docker compose --profile debezium stop debezium
  docker compose --profile debezium rm -f debezium
fi

echo "✅ CDC services stopped"
echo ""
echo "Infrastructure (PostgreSQL, Kafka, monitoring) is still running."
echo "To stop everything: docker compose down -v"
