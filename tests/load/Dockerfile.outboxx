# Multi-stage build for Outboxx
FROM nixos/nix:latest AS builder

WORKDIR /build

# Enable flakes
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

# Copy only flake files first for dependency caching
COPY flake.nix flake.lock ./

# Download and cache Nix dependencies (this layer will be cached)
RUN nix develop --command echo "Dependencies cached"

# Now copy the rest of the project
COPY . .

# Build using nix develop + zig build (ReleaseSafe for profiling with debug symbols)
RUN nix develop --command zig build -Doptimize=ReleaseSafe

# Patch binary to use system linker instead of Nix linker
RUN nix develop --command bash -c " \
    patchelf --set-interpreter /lib/ld-linux-aarch64.so.1 zig-out/bin/outboxx && \
    patchelf --set-rpath /lib/aarch64-linux-gnu zig-out/bin/outboxx \
    "

# Runtime stage - minimal image
FROM debian:bookworm-slim

# Install runtime dependencies + profiling tools + debug symbols
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libpq5 \
    librdkafka1 \
    ca-certificates \
    linux-perf \
    procps \
    git \
    perl \
    libc6-dbg \
    binutils && \
    rm -rf /var/lib/apt/lists/*

# Install FlameGraph tools
RUN git clone --depth 1 https://github.com/brendangregg/FlameGraph /opt/FlameGraph && \
    ln -s /opt/FlameGraph/stackcollapse-perf.pl /usr/local/bin/ && \
    ln -s /opt/FlameGraph/flamegraph.pl /usr/local/bin/

# Copy built binary
COPY --from=builder /build/zig-out/bin/outboxx /app/outboxx

WORKDIR /app

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD pgrep -x outboxx || exit 1

ENTRYPOINT ["/app/outboxx"]
