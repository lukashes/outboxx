# Changelog

All notable changes to Outboxx are documented here.

## Unreleased

### Added

- Release workflow for tags matching `v*.*.*`: verifies the tag against the
  `build.zig.zon` version, then publishes the GHCR image and a GitHub release
  with `linux/amd64` + `linux/arm64` binaries (extracted from the image, so
  they are byte-identical to it) and notes taken from this file's section for
  the released version.
- Auto-tagging: a merge to main whose `build.zig.zon` version has no `v*` tag
  yet (and has its section in this file) is tagged automatically and the
  release workflow is dispatched on the new tag, so a release is one merged
  PR: move Unreleased under the version heading and bump the version.
- Manual GitHub Actions workflow that publishes a multi-stage GHCR image for
  `linux/amd64` and `linux/arm64` using the version from `build.zig.zon`.
- `outboxx --version` and `outboxx --help` for release smoke checks.
