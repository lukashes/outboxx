#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_DIR="$(dirname "$SCRIPT_DIR")"

echo "Stopping load testing infrastructure..."
cd "$LOAD_DIR"

docker compose --profile outboxx --profile debezium down -v

echo "✅ Load testing infrastructure stopped"
echo ""
echo "To remove all data (volumes):"
echo "  docker compose down -v"
echo ""
