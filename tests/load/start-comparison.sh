#!/bin/bash
# Start both Outboxx and Debezium for side-by-side comparison

set -e

echo "🚀 Starting CDC Comparison Stack (Outboxx vs Debezium)"
echo ""

# Start all services (both CDC solutions will start automatically)
echo "📦 Starting all services..."
# shellcheck disable=SC2068
docker compose up -d $@

echo ""
echo "⏳ Waiting for services to be ready..."

# Wait for PostgreSQL
echo "  - PostgreSQL..."
for i in {1..30}; do
    if docker exec load_postgres pg_isready -U postgres > /dev/null 2>&1; then
        echo "    ✅ PostgreSQL ready"
        break
    fi
    sleep 1
done

# Wait for Kafka broker
echo "  - Kafka broker..."
for i in {1..30}; do
    if docker exec load_kafka kafka-topics.sh --bootstrap-server localhost:9092 --list > /dev/null 2>&1; then
        echo "    ✅ Kafka ready"
        break
    fi
    sleep 1
done

# Wait for Debezium Connect
echo "  - Debezium Connect..."
for i in {1..60}; do
    if curl -s http://localhost:8083/ > /dev/null 2>&1; then
        echo "    ✅ Debezium Connect ready"
        break
    fi
    sleep 1
done

# Configure Debezium connector
echo ""
echo "🔧 Configuring Debezium connector..."
echo "   Topic: debezium.load_events"
echo "   Slot: debezium_load_slot"

# Delete connector if exists
curl -s -X DELETE http://localhost:8083/connectors/load-postgres-connector > /dev/null 2>&1 || true

# Create connector
sleep 2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
    --data @"$SCRIPT_DIR/config/debezium-connector.json" \
    http://localhost:8083/connectors)

if echo "$RESPONSE" | grep -q "load-postgres-connector"; then
    echo "   ✅ Debezium connector created"
else
    echo "   ❌ Failed to create Debezium connector"
    echo "   Response: $RESPONSE"
fi

echo ""
echo "✅ CDC Comparison Stack is ready!"
echo ""
echo "📊 Services:"
echo "   • PostgreSQL:      localhost:5433"
echo "   • Debezium API:    http://localhost:8083"
echo "   • Kafka Exporter:  http://localhost:8000/metrics"
echo "   • Prometheus:      http://localhost:9090"
echo "   • Grafana:         http://localhost:3000 (admin/admin)"
echo "   • cAdvisor:        http://localhost:8080"
echo ""
echo "🔄 CDC Solutions running:"
echo "   • Outboxx →  outboxx.load_events"
echo "   • Debezium → debezium.load_events"
echo ""
echo "📈 Run load tests:"
echo "   tests/load/load/run-load.sh steady    # 1000 evt/s × 60 sec"
echo "   tests/load/load/run-load.sh burst     # 10K events burst"
echo "   tests/load/load/run-load.sh ramp      # 100→5000 evt/s"
echo ""
echo "📊 Monitor in Grafana: http://localhost:3000"
echo "   Dashboard will show metrics for both CDC solutions side-by-side"
