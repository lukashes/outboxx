#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Testing currently running CDC solution..."
echo ""

# Check which CDC is running
if docker ps --format '{{.Names}}' | grep -q "load_outboxx"; then
  echo "📊 Current CDC: Outboxx"
  docker logs load_outboxx --tail 5
elif docker ps --format '{{.Names}}' | grep -q "load_debezium"; then
  echo "📊 Current CDC: Debezium"
  curl -s http://localhost:8083/connectors/load-postgres-connector/status | jq -r '.connector.state + " - " + .tasks[0].state'
else
  echo "❌ No CDC solution is running"
  echo "Start one with:"
  echo "  ./start-outboxx.sh"
  echo "  ./start-debezium.sh"
  exit 1
fi

echo ""
echo "Running quick burst test (1000 events)..."
echo ""

# Run small burst load
PGPASSWORD=postgres psql -h localhost -p 5433 -U postgres -d outboxx_load <<EOF > /dev/null 2>&1
DO \$\$
BEGIN
  FOR i IN 1..1000 LOOP
    INSERT INTO load_events (event_type, event_timestamp, user_id)
    VALUES ('test', NOW(), (random() * 10000)::int);
  END LOOP;
END \$\$;
SELECT pg_switch_wal();
EOF

echo "✅ Inserted 1000 events"
echo ""
echo "Wait 3 seconds for CDC processing..."
sleep 3

echo ""
echo "📈 Current metrics:"
curl -s http://localhost:8000/metrics | grep -E "outboxx_events_total|outboxx_replication_lag" | grep -v "^#"

echo ""
echo ""
echo "Open Grafana to see visual metrics:"
echo "  http://localhost:3000"
