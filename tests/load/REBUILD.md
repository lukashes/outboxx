# Rebuilding Outboxx for Benchmarks

When you make changes to Outboxx code, you need to rebuild the Docker image.

## Quick Rebuild

```bash
cd benchmarks

# Stop running containers
docker compose down

# Rebuild Outboxx image
docker compose build outboxx

# Start again
./start-outboxx.sh
```

## What Changed for Profiling

The benchmark Dockerfile was updated to support profiling:

1. **Build mode**: Changed from `ReleaseFast` to `ReleaseSafe`
   - `ReleaseSafe` keeps debug symbols for perf
   - Still optimized, but allows profiling

2. **Added profiling tools**:
   - `linux-perf` - CPU profiling
   - `procps` - Process monitoring (pgrep, pkill)
   - `FlameGraph` - Visualization tools (installed from GitHub)

3. **Docker capabilities**:
   - `SYS_ADMIN` - Required for perf
   - `SYS_PTRACE` - Required for process tracing
   - `seccomp=unconfined` - Allow perf system calls

## Build Options

### Fast Local Build (for quick iteration)

If you're iterating quickly and don't need profiling:

```bash
# Build locally without Docker
cd ..  # project root
zig build -Doptimize=ReleaseFast

# Copy to benchmark config
cp zig-out/bin/outboxx benchmarks/config/outboxx-local

# Use local binary (modify start-outboxx.sh to mount it)
```

### Full Docker Build (for benchmarking)

For actual benchmarks with profiling:

```bash
cd benchmarks
docker compose build --no-cache outboxx  # Force clean build
```

**Note**: Full build takes ~5-10 minutes because it runs in Nix environment.

## Verifying the Build

After rebuild, check:

1. **Binary has debug symbols**:
```bash
docker run --rm bench_outboxx file /app/outboxx
# Should show: "not stripped"
```

2. **Perf is available**:
```bash
docker compose up -d outboxx
docker exec bench_outboxx which perf
# Should output: /usr/bin/perf
```

3. **Can run perf**:
```bash
docker exec bench_outboxx perf --version
# Should show: perf version 6.x.x
```

4. **FlameGraph tools available**:
```bash
docker exec bench_outboxx which stackcollapse-perf.pl
# Should show: /usr/local/bin/stackcollapse-perf.pl
```

## Troubleshooting

### Build fails with "out of space"

Docker images are large. Clean up:
```bash
docker system prune -a
docker volume prune
```

### Perf fails with "Permission denied"

Check Docker capabilities:
```bash
docker inspect bench_outboxx | grep -A 10 CapAdd
# Should show: SYS_ADMIN, SYS_PTRACE
```

### Binary is stripped (no debug symbols)

Check build.zig optimize mode:
```bash
# In Dockerfile.outboxx, should be:
RUN nix develop --command zig build -Doptimize=ReleaseSafe
```

## Build Performance

**First build**: ~5-10 minutes (Nix downloads dependencies)
**Incremental build**: ~2-3 minutes (cached layers)
**Local build** (no Docker): ~30 seconds

## When to Rebuild

Rebuild when:
- ✅ Changed Zig code
- ✅ Changed build.zig configuration
- ✅ Updated dependencies (build.zig.zon)
- ❌ Changed config (config/outboxx.toml) - no rebuild needed
- ❌ Changed benchmark scripts - no rebuild needed

## See Also

- [PROFILING.md](PROFILING.md) - How to profile after rebuilding
- [README.md](README.md) - Main benchmark documentation
