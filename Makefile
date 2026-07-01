.PHONY: help build run test test-integration test-unit clean fmt lint dev install-deps check-deps env-up env-down env-restart env-logs env-status coverage bench bench-collect bench-report bench-compare bench-save bench-ci

# Use direnv to auto-load Nix environment for local development
# This allows commands to work without 'nix develop' wrapper
SHELL := $(CURDIR)/.make-shell
.SHELLFLAGS :=

# Number of passes for bench-save / bench-compare (the minimum time/run is
# kept). Override e.g. `make bench-save BENCH_RUNS=9`.
export BENCH_RUNS ?= 5

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
	@echo "Load Testing (Outboxx vs Debezium stand):"
	@echo "  cd tests/load && make help - Postgres -> CDC -> Kafka benchmark with Grafana"
	@echo ""
	@echo "Component Benchmarks:"
	@echo "  make bench         - Run component benchmarks (view results in terminal)"
	@echo "  make bench-compare - Compare current run with baseline (min of BENCH_RUNS passes)"
	@echo "  make bench-ci      - Compare + write markdown report (used by CI for PR comments)"
	@echo "  make bench-save    - Save current results as new baseline (BENCH_RUNS=N, default 5)"
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

# Load Testing (Outboxx vs Debezium stand)
# The stand lives in tests/load/ with its own Makefile: cd tests/load && make help

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

# Build the benchmark binaries and collect one set of results into
# tests/benchmarks/results/current.json (min of BENCH_RUNS passes). This is the
# reusable unit: the CI workflow runs it once on the PR and once on the base
# branch (in a separate worktree) to compare both on identical hardware.
bench-collect:
	@echo "Building benchmarks..."
	@zig build bench >/dev/null 2>&1
	@echo "Collecting benchmark results..."
	@tests/benchmarks/scripts/collect_results.sh

# Compare the collected results against the baseline, writing a terminal report
# (for the Actions log) and a markdown report at BENCH_REPORT (for a PR
# comment). Reads tests/benchmarks/{baseline/components.json,results/current.json}
# as prepared by the caller. Informational only, never fails the build.
# BASELINE_LABEL describes what the baseline represents in the report header.
BENCH_REPORT ?= tests/benchmarks/results/benchmark-comment.md
export BASELINE_LABEL ?=
bench-report:
	@tests/benchmarks/scripts/compare_results.sh
	@tests/benchmarks/scripts/compare_results.sh --markdown > "$(BENCH_REPORT)"
	@echo "Markdown report written to $(BENCH_REPORT)"

# Local development: collect + terminal comparison against the committed baseline.
bench-compare: bench-collect
	@echo ""
	@tests/benchmarks/scripts/compare_results.sh

# CI entrypoint: collect + terminal & markdown report.
bench-ci: bench-collect bench-report

# Save the current results as the new committed baseline.
bench-save: bench-collect
	@echo ""
	@echo "Updating baseline from current results..."
	@cp tests/benchmarks/results/current.json tests/benchmarks/baseline/components.json
	@echo "Baseline updated: tests/benchmarks/baseline/components.json"
	@echo ""
	@echo "Current metrics are now the new baseline:"
	@jq '.benchmarks | to_entries[] | "\(.key): \(.value.time_avg_us)μs, \(.value.allocations) allocs"' -r tests/benchmarks/baseline/components.json
