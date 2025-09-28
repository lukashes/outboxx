# Outboxx Examples

This directory contains example configurations and architectural designs for Outboxx.

**Purpose**: Documentation, design examples, and reference configurations showing the full vision of the project.

## Files Overview

### Configuration Examples
- **`config.toml`** - Complete configuration example with all available options and design comments
  - Shows both implemented and planned features
  - Serves as architecture documentation
  - Contains detailed comments explaining the design vision

### Reference Files
- **No executable files** - This directory contains only configuration examples and documentation

## For Development

**Note**: For active development, use the `/dev/` directory instead. This directory is for examples and design reference.

### 1. Contributing to Development

For actual development and testing, use the `/dev/` directory which contains all tools needed for contributing.

### 2. View Configuration Design

```bash
# Study the full configuration example
cat docs/examples/config.toml
```

This configuration shows the architectural vision including planned features marked with "DESIGN:" comments.

## Architecture Features Shown

The example configuration demonstrates:

- **Multi-source support**: PostgreSQL (implemented) + MySQL (planned)
- **Multi-sink support**: Kafka (implemented) + Webhooks (planned)
- **Stream-based CDC**: Multiple table streams with independent configuration
- **Security**: Environment variable based password management
- **Extensibility**: Plugin-like architecture for sources and sinks

## Design Philosophy

This configuration file serves as:
1. **Current capabilities** - What works today
2. **Planned features** - Marked with "DESIGN:" comments
3. **Architecture guide** - How the system should evolve

For hands-on development and testing, see `/dev/README.md`.