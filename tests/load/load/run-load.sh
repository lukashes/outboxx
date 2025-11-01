#!/usr/bin/env bash
set -euo pipefail

# Load generator for Outboxx CDC benchmarking
# Usage: ./run-load.sh [steady|burst|mixed]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO="${1:-steady}"

# PostgreSQL connection
export PGHOST="localhost"
export PGPORT="5433"
export PGDATABASE="outboxx_load"
export PGUSER="postgres"
export PGPASSWORD="postgres"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')]${NC} $*"
}

# Wait for PostgreSQL
wait_for_postgres() {
    log "Waiting for PostgreSQL..."
    until psql -c '\q' 2>/dev/null; do
        sleep 1
    done
    log "PostgreSQL is ready"
}

# Run SQL scenario
run_scenario() {
    local scenario=$1
    local sql_file="${SCRIPT_DIR}/${scenario}.sql"

    if [[ ! -f "$sql_file" ]]; then
        warn "Scenario file not found: $sql_file"
        exit 1
    fi

    log "Running scenario: $scenario"
    log "SQL file: $sql_file"

    psql -f "$sql_file"

    log "Scenario completed: $scenario"
}

# Run scenario with separate transactions (for realistic CDC)
run_scenario_batched() {
    local scenario=$1
    local sql_file="${SCRIPT_DIR}/${scenario}.sql"
    local num_batches=${2:-60}
    local sleep_seconds=${3:-1}

    if [[ ! -f "$sql_file" ]]; then
        warn "Scenario file not found: $sql_file"
        exit 1
    fi

    log "Running batched scenario: $scenario"
    log "Batches: $num_batches, Interval: ${sleep_seconds}s"
    log "Each batch = separate transaction (realistic CDC)"

    for ((batch=1; batch<=num_batches; batch++)); do
        psql -f "$sql_file" -q 2>&1 | grep -v "^INSERT"

        if [[ $((batch % 10)) -eq 0 ]]; then
            log "Batch $batch/$num_batches completed"
        fi

        if [[ $batch -lt $num_batches ]]; then
            sleep "$sleep_seconds"
        fi
    done

    log "Scenario completed: $scenario ($num_batches batches)"
}

# Main
wait_for_postgres

case "$SCENARIO" in
    steady)
        log "Starting STEADY load (1000 events/sec for 60 seconds)"
        run_scenario "steady"
        ;;
    burst)
        log "Starting BURST load (10000 events in 5 seconds)"
        run_scenario "burst"
        ;;
    mixed)
        log "Starting MIXED load (60% INSERT, 30% UPDATE, 10% DELETE)"
        run_scenario "mixed"
        ;;
    ramp)
        log "Starting RAMP load (100 -> 10000 events/sec)"
        log "Each step: 30 seconds with separate commits"
        log "Watch Grafana to find when lag starts growing"
        run_scenario "ramp"
        ;;
    *)
        warn "Unknown scenario: $SCENARIO"
        warn "Usage: $0 [steady|burst|mixed|ramp]"
        exit 1
        ;;
esac

log "Load generation finished. Check Grafana at http://localhost:3000"
log "Credentials: admin/admin"
