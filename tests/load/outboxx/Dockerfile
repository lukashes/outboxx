FROM nixos/nix:2.24.10

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /src

# Cache the Nix devshell in a separate layer keyed on the flake files
COPY flake.nix flake.lock ./
RUN nix develop --command echo "deps cached"

# Build outboxx from the local checkout (build context is the repo root)
COPY . .
RUN nix develop --command zig build -Doptimize=ReleaseFast

WORKDIR /app
ENTRYPOINT ["/src/zig-out/bin/outboxx"]
