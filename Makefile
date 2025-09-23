.PHONY: help build run test clean fmt dev install-deps check-deps env-up env-down env-restart env-logs env-status nix-shell

# Default target
help:
	@echo "Outboxx Development Commands:"
	@echo ""
	@echo "Build & Run:"
	@echo "  make build         - Build the project"
	@echo "  make run           - Run the application"
	@echo "  make test          - Run unit tests"
	@echo "  make test-integration - Run integration tests"
	@echo "  make test-all      - Run all tests with database setup"
	@echo "  make dev           - Development workflow (format + test + build)"
	@echo "  make fmt           - Format code"
	@echo "  make clean         - Clean build artifacts"
	@echo ""
	@echo "Development Environment:"
	@echo "  make env-up        - Start PostgreSQL development environment"
	@echo "  make env-down      - Stop development environment"
	@echo "  make env-restart   - Restart development environment"
	@echo "  make env-logs      - Show PostgreSQL logs"
	@echo "  make env-status    - Show environment status"
	@echo ""
	@echo "Dependencies:"
	@echo "  make nix-shell     - Enter Nix development shell (recommended)"
	@echo "  make check-deps    - Check system dependencies"
	@echo "  make install-deps  - Install system dependencies (Ubuntu/Debian)"
	@echo ""

# Build the project
build:
	zig build

# Run the application
run:
	zig build run

# Run unit tests
test:
	zig build test && echo "Success: Unit tests passed"

# Run integration tests (requires PostgreSQL)
test-integration:
	zig build test-integration && echo "Success: Integration tests passed"
# Run all tests with database setup
test-all: env-up
	@echo "Waiting for PostgreSQL to be ready..."
	@sleep 5
	@docker exec outboxx-postgres pg_isready -U postgres -d outboxx_test
	zig build test && echo "Success: Unit tests passed!"
	zig build test-integration && echo "Success: Integration tests passed!"

# Development workflow
dev:
	zig build dev

# Format code
fmt:
	zig build fmt

# Clean build artifacts
clean:
	zig build clean

# Check if required system dependencies are installed
check-deps:
	@echo "Checking system dependencies..."
	@command -v zig >/dev/null 2>&1 || { echo "ERROR: Zig is not installed"; exit 1; }
	@echo "OK: Zig: $$(zig version)"
	@pkg-config --exists libpq 2>/dev/null || { echo "ERROR: libpq (PostgreSQL client library) is not installed"; exit 1; }
	@echo "OK: libpq: $$(pkg-config --modversion libpq)"
	@echo "All dependencies are installed!"

# Install system dependencies (Ubuntu/Debian)
install-deps:
	@echo "Installing system dependencies for Ubuntu/Debian..."
	sudo apt update
	sudo apt install -y libpq-dev postgresql-client
	@echo "Dependencies installed!"
	@echo "Note: You may also want to install PostgreSQL server and Kafka for development:"
	@echo "  sudo apt install -y postgresql"

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
	docker-compose down

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

# Nix development shell
nix-shell:
	@if command -v nix >/dev/null 2>&1; then \
		echo "Entering Nix development shell..."; \
		nix --extra-experimental-features "nix-command flakes" develop; \
	else \
		echo "ERROR: Nix is not installed. Installing Nix (Determinate Systems installer):"; \
		echo "curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install"; \
		echo ""; \
		echo "After installation, restart your shell and run 'make nix-shell' again."; \
		exit 1; \
	fi