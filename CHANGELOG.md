# Changelog

All notable changes to Outboxx are documented here.

## Unreleased

### Added

- Release workflow for tags matching `v*.*.*`.
- Manual GitHub Actions workflow that publishes a multi-stage GHCR image for
  `linux/amd64` and `linux/arm64` using the version from `build.zig.zon`.
- `outboxx --version` and `outboxx --help` for release smoke checks.
