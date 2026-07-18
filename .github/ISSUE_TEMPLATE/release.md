---
name: Release
about: Checklist for cutting a release
title: "Release X.Y.Z"
labels: release
---

Preconditions:

- [ ] The X.Y.Z milestone is empty: every issue closed or moved out
- [ ] CI on main is green
- [ ] Load stand run against main: `make check-gaps` reports no gaps

Release PR:

- [ ] CHANGELOG.md: move the `## Unreleased` content under `## X.Y.Z - YYYY-MM-DD`
- [ ] build.zig.zon: `.version = "X.Y.Z"`
- [ ] build.zig: the `-Dversion` fallback is `orelse "X.Y.Z"`
- [ ] `make build && ./zig-out/bin/outboxx --version` prints X.Y.Z
- [ ] Merge the PR. The merge is the release trigger: auto-tag mints `vX.Y.Z` and dispatches the release workflow

Definition of Done. The merge hands off to automation (auto-tag, dispatch,
build, GHCR, release), and each hop can fail silently; these verify the
outcome, not the actions above:

- [ ] Tag `vX.Y.Z` exists and points at the merge commit (auto-tag can skip,
      e.g. on a CHANGELOG heading typo)
- [ ] The release workflow run is green
- [ ] `docker run --rm ghcr.io/lukashes/outboxx:X.Y.Z --version` prints X.Y.Z (amd64 and arm64)
- [ ] The GitHub release exists and its notes match the CHANGELOG section
- [ ] The X.Y.Z milestone is closed
