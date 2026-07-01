FROM nixos/nix:2.24.10

ARG OUTBOXX_REF=main

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /src
RUN git clone --depth 1 --branch "${OUTBOXX_REF}" https://github.com/lukashes/outboxx.git .
RUN nix develop --command zig build -Doptimize=ReleaseFast

WORKDIR /app
ENTRYPOINT ["/src/zig-out/bin/outboxx"]
