#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_DIR="$(dirname "$SCRIPT_DIR")"
CDC="${1:-outboxx}"

# Validation
check_prerequisites() {
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker is not installed"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        echo "Error: Docker daemon is not running"
        exit 1
    fi
}

# Supported CDC solutions
SUPPORTED_CDC=("outboxx" "debezium")
if [[ ! " ${SUPPORTED_CDC[@]} " =~ " ${CDC} " ]]; then
    echo "Error: Unsupported CDC solution: $CDC"
    echo "Supported: ${SUPPORTED_CDC[*]}"
    exit 1
fi

echo "Starting load testing infrastructure with $CDC..."
cd "$LOAD_DIR"

# Check prerequisites
check_prerequisites

# Start core infrastructure
echo "Starting core infrastructure (PostgreSQL, Kafka, monitoring)..."
docker compose up -d postgres kafka prometheus grafana cadvisor kafka-exporter

# Wait for PostgreSQL
echo "Waiting for PostgreSQL..."
until docker exec load_postgres pg_isready -U postgres > /dev/null 2>&1; do
  sleep 1
done

# Wait for Kafka
echo "Waiting for Kafka..."
sleep 5

# Start CDC solution
echo "Starting $CDC CDC..."
docker compose --profile "$CDC" up -d "$CDC"

# Wait for CDC to be ready
if [ "$CDC" = "debezium" ]; then
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
echo "✅ Load testing stack is running with $CDC"
echo ""
echo "Access points:"
echo "  Grafana:    http://localhost:3000 (admin/admin)"
echo "  Prometheus: http://localhost:9090"
echo "  cAdvisor:   http://localhost:8080"
echo ""
if [ "$CDC" = "debezium" ]; then
    echo "  Debezium API: http://localhost:8083"
    echo ""
fi
echo "Run load tests:"
echo "  $SCRIPT_DIR/run-scenario.sh steady"
echo "  $SCRIPT_DIR/run-scenario.sh burst"
echo "  $SCRIPT_DIR/run-scenario.sh ramp"
echo "  $SCRIPT_DIR/run-scenario.sh mixed"
echo ""
echo "Switch CDC:"
echo "  $SCRIPT_DIR/switch.sh <cdc-name>"
echo ""
