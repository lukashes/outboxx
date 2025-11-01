# Benchmarking Framework Implementation Plan

## Overview

This plan describes the implementation of a comprehensive benchmarking framework for Outboxx, separating component benchmarks (micro-level) from load testing (macro-level).

## Goals

1. **Component Benchmarks**: Use zbench to measure performance of individual components (time/op, allocations/op)
2. **Load Testing**: Keep existing Grafana-based infrastructure for system-level performance testing
3. **Organization**: Move all testing infrastructure under `tests/` directory
4. **Baseline Tracking**: Enable regression detection through baseline comparison

## Architecture

### Directory Structure

```
tests/
├── e2e/                    # Existing: End-to-end tests
├── test_helpers.zig        # Existing: Shared test utilities
├── benchmarks/             # NEW: Component benchmarks
│   ├── components/
│   │   ├── decoder_bench.zig
│   │   ├── serializer_bench.zig
│   │   └── kafka_bench.zig
│   ├── baseline/
│   │   └── components.json
│   └── README.md
└── load/                   # MOVED: Load testing infrastructure
    ├── docker-compose.yml
    ├── config/
    ├── exporter/
    ├── grafana/
    ├── load/
    ├── results/
    └── README.md
```

### Benchmark vs Load Testing

**Component Benchmarks (zbench)**:
- Micro-level: individual functions and components
- Metrics: time/op, memory/op, allocations/op
- Purpose: Find bottlenecks, track regressions
- Fast iteration: no external dependencies

**Load Testing (Grafana stack)**:
- Macro-level: entire system under load
- Metrics: throughput, latency under load, breaking point
- Purpose: Validate production readiness
- Realistic scenarios: PostgreSQL + Kafka + Outboxx

## Implementation Phases

### Phase 1: Reorganization (High Priority)

**Goal**: Restructure project to separate benchmarks and load testing

**Tasks**:

1. Create new directories:
   - `tests/benchmarks/` for component benchmarks
   - `tests/load/` for load testing

2. Move `benchmarks/` → `tests/load/`:
   - All files: docker-compose.yml, config/, exporter/, grafana/, load/, results/
   - Preserve git history with `git mv`

3. Update paths in shell scripts:
   - `tests/load/*.sh` - update relative paths
   - Working directory references

4. Update `tests/load/docker-compose.yml`:
   - Volume mount paths
   - Config file paths

5. Update Makefile:
   - `load-*` targets for `tests/load/`
   - Prepare `bench-*` targets for Phase 2

**Deliverables**:
- ✅ Reorganized directory structure
- ✅ All load testing scripts working from new location
- ✅ Updated Makefile

---

### Phase 2: Component Benchmarks (High Priority)

**Goal**: Implement component benchmarks using zbench

**Tasks**:

1. Add zbench dependency:
   - Update `build.zig.zon` with zbench (branch: zig-0.15.1)
   - Verify compatibility with Zig 0.15.1
   - Update flake.nix if needed

2. Create benchmark infrastructure:
   - `tests/benchmarks/components/decoder_bench.zig`:
     - Benchmark PgOutputDecoder.decode() for INSERT/UPDATE/DELETE
     - Measure allocations and time
   - `tests/benchmarks/components/serializer_bench.zig`:
     - Benchmark JsonSerializer.serialize()
     - Different payload sizes
   - `tests/benchmarks/components/kafka_bench.zig`:
     - Benchmark KafkaProducer.produce() + flush()
     - Measure end-to-end Kafka latency

3. Integrate into build system:
   - `build.zig`: add "bench" step
   - Link zbench module to benchmark tests
   - Compile with ReleaseFast optimization

4. Baseline tracking:
   - Create `tests/benchmarks/baseline/` directory
   - Implement JSON export from zbench output
   - Comparison script: current vs baseline
   - Store baseline in Git

5. Makefile commands:
   ```makefile
   bench:          # Run component benchmarks
   bench-ci:       # Run with JSON output
   bench-compare:  # Compare with baseline
   bench-baseline: # Update baseline
   ```

**Deliverables**:
- ✅ zbench integrated into project
- ✅ Component benchmarks for decoder, serializer, kafka
- ✅ Baseline tracking system
- ✅ Makefile commands

---

### Phase 3: Polish Load Testing (Medium Priority)

**Goal**: Improve existing load testing infrastructure

**Tasks**:

1. Script improvements:
   - Unify start scripts (consistent error handling)
   - Add environment validation (check Docker, ports)
   - Better output formatting

2. Documentation:
   - Update `tests/load/README.md` with new paths
   - Add troubleshooting section
   - Examples of interpreting Grafana metrics
   - Best practices for load testing

3. Results automation:
   - Script to snapshot Prometheus metrics
   - Markdown template for documenting results
   - Auto-save to `tests/load/results/` with timestamp
   - Git-friendly format (JSON + markdown summary)

4. Optional: CI/CD for load tests:
   - GitHub Actions workflow
   - Periodic load tests (nightly)
   - Save results as artifacts

**Deliverables**:
- ✅ Improved shell scripts
- ✅ Enhanced documentation
- ✅ Automated result saving

---

### Phase 4: Documentation (Medium Priority)

**Goal**: Update project documentation with new structure

**Tasks**:

1. Update `CLAUDE.md`:
   - Testing section with new structure
   - Explain difference: benchmarks vs load testing
   - Quick start for both approaches

2. Update root `README.md`:
   - Add links to `tests/benchmarks/` and `tests/load/`
   - Testing section overview

3. Create `tests/benchmarks/README.md`:
   - How to run benchmarks
   - How to interpret results
   - How to add new benchmarks
   - Baseline comparison workflow

4. Update `tests/load/README.md`:
   - Reflect new paths
   - Updated examples
   - Link to original benchmarks/ docs

5. Finalize Makefile with all commands:
   ```makefile
   # Load testing
   load-up:       # Start infrastructure
   load-test:     # Run load scenario
   load-compare:  # Outboxx vs Debezium

   # Component benchmarks
   bench:         # Run benchmarks
   bench-ci:      # JSON output
   bench-compare: # Compare with baseline
   bench-baseline:# Update baseline

   # Combined
   test-all:      # All tests + benchmarks
   ```

**Deliverables**:
- ✅ Updated documentation
- ✅ Clear quick start guides
- ✅ Comprehensive Makefile

---

### Phase 5: CI/CD Integration (Low Priority)

**Goal**: Automate benchmark execution and regression detection

**Tasks**:

1. GitHub Actions workflow:
   - `.github/workflows/benchmarks.yml`
   - Trigger: on PR + on push to main
   - Run component benchmarks
   - Compare with baseline from main branch

2. Regression detection:
   - Define acceptable threshold (e.g., 10% slower = fail)
   - Clear failure messages
   - Which component regressed and by how much

3. PR comments:
   - Post benchmark results as PR comment
   - Table format: before vs after
   - Visual indicators (✅ improved, ⚠️ degraded)

4. Artifact storage:
   - Save benchmark JSON as GitHub artifact
   - Historical tracking

**Deliverables**:
- ✅ Automated benchmarks in CI/CD
- ✅ Regression detection
- ✅ PR feedback

---

## Success Criteria

### Phase 1
- [ ] All load testing scripts work from `tests/load/`
- [ ] No broken links in documentation
- [ ] `make load-up` works

### Phase 2
- [ ] `make bench` runs successfully
- [ ] Benchmarks measure time and allocations
- [ ] Baseline comparison detects regressions
- [ ] JSON export works for CI/CD

### Phase 3
- [ ] Load testing scripts have error handling
- [ ] Documentation is comprehensive
- [ ] Results auto-save to `tests/load/results/`

### Phase 4
- [ ] All documentation updated
- [ ] Quick start guides complete
- [ ] Makefile has all commands

### Phase 5
- [ ] CI/CD runs benchmarks on PRs
- [ ] Regression detection works
- [ ] PR comments show results

---

## Timeline

**Phase 1**: ~2-3 hours (reorganization)
**Phase 2**: ~4-6 hours (benchmark framework)
**Phase 3**: ~2-3 hours (polish)
**Phase 4**: ~1-2 hours (documentation)
**Phase 5**: ~2-3 hours (CI/CD)

**Total**: ~11-17 hours

---

## Notes

- Phases 1 and 2 are **critical** - provide immediate value
- Phase 3 improves existing infrastructure
- Phases 4 and 5 can be done incrementally
- Each phase is independently deployable

---

## References

- [zbench GitHub](https://github.com/hendriknielaender/zBench)
- Existing load testing: `tests/load/README.md` (after migration)
- Zig benchmarking best practices: TigerBeetle benchmarks
