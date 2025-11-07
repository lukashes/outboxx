#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_DIR="$(dirname "$SCRIPT_DIR")"
SCENARIO="${1:-}"

if [ -z "$SCENARIO" ]; then
    echo "Usage: $0 <scenario>"
    echo ""
    echo "Available scenarios:"
    echo "  steady - 1000 events/sec for 60 seconds (sustained throughput)"
    echo "  burst  - 10,000 events as fast as possible (peak performance)"
    echo "  ramp   - Gradual increase 100→5000 events/sec (find breaking point)"
    echo "  mixed  - 60% INSERT, 30% UPDATE, 10% DELETE (realistic workload)"
    exit 1
fi

SCENARIO_FILE="$LOAD_DIR/scenarios/${SCENARIO}.sql"

if [ ! -f "$SCENARIO_FILE" ]; then
    echo "Error: Scenario file not found: $SCENARIO_FILE"
    echo "Available scenarios: steady, burst, ramp, mixed"
    exit 1
fi

echo "Running load scenario: $SCENARIO"
echo "Scenario file: $SCENARIO_FILE"
echo ""

# Execute scenario
docker exec -i load_postgres psql -U postgres -d outboxx_load < "$SCENARIO_FILE"

echo ""
echo "✅ Scenario '$SCENARIO' completed"
echo ""
echo "View metrics in Grafana: http://localhost:3000"
echo ""
