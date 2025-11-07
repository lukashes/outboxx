#!/usr/bin/env bash
set -euo pipefail

echo "Load Testing Infrastructure Status"
echo "=================================="
echo ""

# Check running containers
POSTGRES_RUNNING=$(docker ps --filter "name=load_postgres" --format "{{.Status}}" 2>/dev/null || echo "not running")
KAFKA_RUNNING=$(docker ps --filter "name=load_kafka" --format "{{.Status}}" 2>/dev/null || echo "not running")
OUTBOXX_RUNNING=$(docker ps --filter "name=load_outboxx" --format "{{.Status}}" 2>/dev/null || echo "not running")
DEBEZIUM_RUNNING=$(docker ps --filter "name=load_debezium" --format "{{.Status}}" 2>/dev/null || echo "not running")
PROMETHEUS_RUNNING=$(docker ps --filter "name=load_prometheus" --format "{{.Status}}" 2>/dev/null || echo "not running")
GRAFANA_RUNNING=$(docker ps --filter "name=load_grafana" --format "{{.Status}}" 2>/dev/null || echo "not running")
CADVISOR_RUNNING=$(docker ps --filter "name=load_cadvisor" --format "{{.Status}}" 2>/dev/null || echo "not running")
EXPORTER_RUNNING=$(docker ps --filter "name=load_kafka_exporter" --format "{{.Status}}" 2>/dev/null || echo "not running")

# Core infrastructure
echo "Core Infrastructure:"
echo "  PostgreSQL:     $POSTGRES_RUNNING"
echo "  Kafka:          $KAFKA_RUNNING"
echo "  Prometheus:     $PROMETHEUS_RUNNING"
echo "  Grafana:        $GRAFANA_RUNNING"
echo "  cAdvisor:       $CADVISOR_RUNNING"
echo "  Kafka Exporter: $EXPORTER_RUNNING"
echo ""

# CDC solutions
echo "CDC Solutions:"
if [ -n "$OUTBOXX_RUNNING" ] && [ "$OUTBOXX_RUNNING" != "not running" ]; then
    echo "  ✅ Outboxx:    $OUTBOXX_RUNNING"
    ACTIVE_CDC="outboxx"
else
    echo "  ⚫ Outboxx:    stopped"
fi

if [ -n "$DEBEZIUM_RUNNING" ] && [ "$DEBEZIUM_RUNNING" != "not running" ]; then
    echo "  ✅ Debezium:   $DEBEZIUM_RUNNING"
    ACTIVE_CDC="debezium"
else
    echo "  ⚫ Debezium:   stopped"
fi
echo ""

# Access points
if [ "${ACTIVE_CDC:-}" ]; then
    echo "Active CDC: $ACTIVE_CDC"
    echo ""
fi

echo "Access Points:"
echo "  Grafana:    http://localhost:3000 (admin/admin)"
echo "  Prometheus: http://localhost:9090"
echo "  cAdvisor:   http://localhost:8080"
if [ -n "$DEBEZIUM_RUNNING" ] && [ "$DEBEZIUM_RUNNING" != "not running" ]; then
    echo "  Debezium:   http://localhost:8083"
fi
echo ""

# Container logs
if [ "${ACTIVE_CDC:-}" ]; then
    echo "View CDC logs:"
    echo "  docker logs -f load_${ACTIVE_CDC}"
    echo ""
fi
