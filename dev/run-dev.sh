#!/bin/bash
# Development runner script for Outboxx CDC

set -e

echo "🚀 Starting Outboxx Development Environment"
echo "=========================================="

# Check if we're in the right directory
if [ ! -f "build.zig" ]; then
    echo "❌ Error: Please run this script from the project root directory"
    exit 1
fi

# Check if development environment is running
if ! docker compose ps postgres | grep -q "running"; then
    echo "📦 Starting PostgreSQL and Kafka..."
    make env-up
    echo "✅ Development environment ready"
else
    echo "✅ PostgreSQL and Kafka already running"
fi

# Set environment variables
export POSTGRES_URL="postgres://postgres:password@localhost:5432/outboxx_test?sslmode=disable"
echo "🔐 PostgreSQL connection set"

# Show configuration info
echo ""
echo "📋 Configuration:"
echo "   Config file: dev/config.toml"
echo "   PostgreSQL: localhost:5432/outboxx_test"
echo "   Kafka: localhost:9092"
echo "   Topic prefix: outboxx_dev"
echo ""

# Check if build works
echo "🔨 Building application..."
if nix develop --command zig build; then
    echo "✅ Build successful"
else
    echo "❌ Build failed"
    exit 1
fi

echo ""
echo "🎯 Running Outboxx CDC..."
echo "   Press Ctrl+C to stop"
echo ""

# Run the application
./zig-out/bin/outboxx --config dev/config.toml