#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_DIR="$(dirname "$SCRIPT_DIR")"
TARGET_CDC="${1:-}"

if [ -z "$TARGET_CDC" ]; then
    echo "Usage: $0 <cdc-name>"
    echo "Supported CDC: outboxx, debezium"
    exit 1
fi

# Supported CDC solutions
SUPPORTED_CDC=("outboxx" "debezium")
if [[ ! " ${SUPPORTED_CDC[@]} " =~ " ${TARGET_CDC} " ]]; then
    echo "Error: Unsupported CDC solution: $TARGET_CDC"
    echo "Supported: ${SUPPORTED_CDC[*]}"
    exit 1
fi

cd "$LOAD_DIR"

# Detect current CDC
CURRENT_CDC=""
if docker ps --format '{{.Names}}' | grep -q "load_outboxx"; then
    CURRENT_CDC="outboxx"
elif docker ps --format '{{.Names}}' | grep -q "load_debezium"; then
    CURRENT_CDC="debezium"
fi

if [ "$CURRENT_CDC" = "$TARGET_CDC" ]; then
    echo "Already running $TARGET_CDC"
    exit 0
fi

echo "Switching from ${CURRENT_CDC:-none} to $TARGET_CDC..."

# Stop current CDC
if [ -n "$CURRENT_CDC" ]; then
    echo "Stopping $CURRENT_CDC..."
    docker compose --profile "$CURRENT_CDC" stop "$CURRENT_CDC"
    docker compose --profile "$CURRENT_CDC" rm -f "$CURRENT_CDC"
fi

# Start target CDC
echo "Starting $TARGET_CDC..."
docker compose --profile "$TARGET_CDC" up -d "$TARGET_CDC"

# Wait for Debezium and register connector
if [ "$TARGET_CDC" = "debezium" ]; then
    echo "Waiting for Debezium Kafka Connect..."
    until curl -s -o /dev/null -w "%{http_code}" http://localhost:8083/ | grep -q "200"; do
        sleep 2
    done

    echo "Registering Debezium connector..."
    curl -X POST -H "Content-Type: application/json" \
        --data @"$LOAD_DIR/cdc/debezium/connector.json" \
        http://localhost:8083/connectors 2>/dev/null || echo "(Connector may already exist)"
fi

echo ""
echo "✅ Switched to $TARGET_CDC"
echo ""
echo "Run load test to see fresh metrics:"
echo "  $SCRIPT_DIR/run-scenario.sh steady"
echo ""
