FROM nixos/nix:2.24.10

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /src

# Cache the Nix devshell in a separate layer keyed on the flake files
COPY flake.nix flake.lock ./
RUN nix develop --command echo "deps cached"

# Build outboxx from the local checkout (build context is the repo root).
# -Dlog_level=debug keeps ReleaseFast perf but compiles in std.log.debug so the
# load stand can trace teardown / fail-fast behavior.
COPY . .
RUN nix develop --command zig build -Doptimize=ReleaseFast -Dlog_level=debug

WORKDIR /app
EXPOSE 9464
ENTRYPOINT ["/src/zig-out/bin/outboxx"]
