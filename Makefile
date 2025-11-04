.PHONY: help build run test test-integration test-unit clean fmt lint dev install-deps check-deps env-up env-down env-restart env-logs env-status coverage load-up load-down load-test bench

# Use direnv to auto-load Nix environment for local development
# This allows commands to work without 'nix develop' wrapper
SHELL := $(CURDIR)/.make-shell
.SHELLFLAGS :=

# Helper function for running commands with spinner
# Captures both stdout and stderr, shows full output on failure
define run_with_spinner
	@(while true; do for s in / - \\ \|; do printf "\b$$s"; sleep 0.1; done; done) & spinner=$$!; \
	$(1) >test_output.tmp 2>&1; result=$$?; \
	kill $$spinner 2>/dev/null; printf "\b"; \
	if [ $$result -eq 0 ]; then \
		echo "✅ $(2) passed"; \
		rm -f test_output.tmp; \
	else \
		echo "❌ $(2) failed"; \
		echo ""; \
		echo "Full output:"; \
		echo "----------------------------------------"; \
		cat test_output.tmp; \
		echo "----------------------------------------"; \
		rm -f test_output.tmp; \
		exit 1; \
	fi
endef

# Default target
help:
	@echo "Outboxx Development Commands:"
	@echo ""
	@echo "Build & Run:"
	@echo "  make build         - Build the project"
	@echo "  make run           - Run the application"
	@echo "  make test-unit     - Run unit tests"
	@echo "  make test-integration - Run integration tests"
	@echo "  make test-e2e      - Run E2E tests (PostgreSQL + Kafka full pipeline)"
	@echo "  make test          - Run all tests with database setup"
	@echo "  make dev           - Development workflow (format + test + build)"
	@echo "  make fmt           - Format code"
	@echo "  make lint          - Check code formatting"
	@echo "  make clean         - Clean build artifacts"
	@echo ""
	@echo "Development Environment:"
	@echo "  make env-up        - Start PostgreSQL development environment"
	@echo "  make env-down      - Stop development environment"
	@echo "  make env-restart   - Restart development environment"
	@echo "  make env-logs      - Show PostgreSQL logs"
	@echo "  make env-status    - Show environment status"
	@echo ""
	@echo "Load Testing:"
	@echo "  make load-up       - Start load testing infrastructure (Grafana + Prometheus)"
	@echo "  make load-down     - Stop load testing infrastructure"
	@echo "  make load-test     - Run load test scenario (SCENARIO=steady|burst|mixed|ramp)"
	@echo ""
	@echo "Component Benchmarks:"
	@echo "  make bench         - Run component benchmarks (decoder, serializer, kafka)"
	@echo ""
	@echo "Dependencies:"
	@echo "  make check-deps    - Check system dependencies"
	@echo "  make install-deps  - Install system dependencies (Ubuntu/Debian)"
	@echo ""

# Build the project
build:
# macro-prefix-map is not supported at darwin
	@echo "zig build"
	@zig build

# Run the application
run:
	zig build run

# Run unit tests
test-unit:
	@echo -n "Running unit tests... "
	$(call run_with_spinner,zig build test,Unit tests)

# Run integration tests (requires PostgreSQL)
test-integration:
	@echo -n "Running integration tests... "
	$(call run_with_spinner,zig build test-integration,Integration tests)

# Run E2E tests (requires PostgreSQL + Kafka)
test-e2e:
	@echo -n "Running E2E tests... "
	$(call run_with_spinner,zig build test-e2e,E2E tests)

# Run all tests with database setup
test: env-up test-unit test-integration test-e2e

# Development workflow
dev:
	zig build dev

# Format code
fmt:
	zig build fmt

# Check code formatting
lint:
	@echo "Checking code formatting..."
	zig fmt --check src/
	@echo "Success: Code formatting is correct"

# Clean build artifacts
clean:
	@zig build clean
	@rm -f test_errors.tmp

# Generate coverage report
coverage:
	@echo "Generating test coverage report..."
	@test_funcs=$$(grep -r "test \"" src/ --include="*.zig" | wc -l); \
	pub_funcs=$$(grep -r "pub fn" src/ --include="*.zig" | grep -v "_test.zig" | wc -l); \
	if [ "$$test_funcs" -eq 0 ]; then \
		echo "FAIL: No tests found"; \
		exit 1; \
	fi; \
	coverage_ratio=$$((test_funcs * 100 / (pub_funcs + 1))); \
	echo "Test coverage estimate: $${coverage_ratio}% ($$test_funcs tests for $$pub_funcs public functions)"; \
	if [ "$$coverage_ratio" -lt 30 ]; then \
		echo "WARN: Low test coverage - consider adding more tests"; \
	else \
		echo "PASS: Test coverage looks reasonable"; \
	fi

# Check if required system dependencies are installed
check-deps:
	@echo "Checking system dependencies..."
	@command -v zig >/dev/null 2>&1 || { echo "ERROR: Zig is not installed"; exit 1; }
	@echo "OK: Zig: $$(zig version)"
	@pkg-config --exists libpq 2>/dev/null || { echo "ERROR: libpq (PostgreSQL client library) is not installed"; exit 1; }
	@echo "OK: libpq: $$(pkg-config --modversion libpq)"
	@echo "All dependencies are installed!"

# Development environment management
env-up:
	@echo "Starting PostgreSQL development environment..."
	docker-compose up -d
	@echo "Waiting for PostgreSQL to be ready..."
	@sleep 5
	@echo "Development environment is ready!"
	@echo "PostgreSQL: localhost:5432"
	@echo "Database: outboxx_test"
	@echo "User: postgres / Password: password"

env-down:
	@echo "Stopping development environment..."
	docker-compose down -v

env-restart:
	@echo "Restarting development environment..."
	docker-compose restart
	@echo "Waiting for PostgreSQL to be ready..."
	@sleep 5
	@echo "Development environment restarted!"

env-logs:
	@echo "PostgreSQL logs (Ctrl+C to exit):"
	docker-compose logs -f postgres

env-status:
	@echo "Development environment status:"
	docker-compose ps

# Load Testing (Grafana + Prometheus stack)
load-up:
	@echo "Starting load testing infrastructure..."
	@cd tests/load && docker compose up -d
	@echo "Load testing environment is ready!"
	@echo ""
	@echo "Services:"
	@echo "  • Grafana:    http://localhost:3000 (admin/admin)"
	@echo "  • Prometheus: http://localhost:9090"
	@echo "  • cAdvisor:   http://localhost:8080"
	@echo "  • PostgreSQL: localhost:5433"
	@echo ""
	@echo "Run load tests:"
	@echo "  make load-test SCENARIO=steady"
	@echo "  make load-test SCENARIO=burst"

load-down:
	@echo "Stopping load testing infrastructure..."
	@cd tests/load && docker compose down -v

load-test:
	@if [ -z "$(SCENARIO)" ]; then \
		echo "Usage: make load-test SCENARIO=<scenario>"; \
		echo ""; \
		echo "Available scenarios:"; \
		echo "  steady - 1000 evt/s for 60 seconds"; \
		echo "  burst  - 10K events as fast as possible"; \
		echo "  mixed  - 60% INSERT, 30% UPDATE, 10% DELETE"; \
		echo "  ramp   - Gradual 100→5000 evt/s"; \
		exit 1; \
	fi
	@echo "Running load test: $(SCENARIO)"
	@tests/load/load/run-load.sh $(SCENARIO)

# Component Benchmarks (zbench)
bench:
	@echo "Compiling component benchmarks..."
	@zig build bench >/dev/null 2>&1
	@echo "Running benchmarks..."
	@./zig-out/bin/serializer_bench
	@echo ""
	@./zig-out/bin/decoder_bench
	@echo ""
	@./zig-out/bin/match_streams_bench
	@echo ""
	@./zig-out/bin/partition_key_bench
	@echo ""
	@./zig-out/bin/kafka_bench
	@echo ""
	@./zig-out/bin/message_processor_bench
