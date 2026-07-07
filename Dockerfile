FROM nixos/nix:2.24.10 AS builder

ARG VERSION=0.2.0

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /src

# Cache the Nix dev shell before copying the full repository.
COPY flake.nix flake.lock ./
RUN nix develop --command echo "deps cached"

COPY . .
RUN nix develop --command zig build -Doptimize=ReleaseSafe -Dversion="${VERSION}"
RUN nix develop --command bash -c 'set -euo pipefail; \
    mkdir -p /runtime/app /runtime/etc/ssl/certs; \
    cp zig-out/bin/outboxx /runtime/app/outboxx; \
    ldd zig-out/bin/outboxx | \
      awk "/=> \/nix\/store/ {print \$(NF-1)} /^\/nix\/store/ {print \$1}" | \
      sort -u > /tmp/outboxx-libs; \
    readelf -l zig-out/bin/outboxx | \
      awk "/Requesting program interpreter/ {gsub(/[][]/, \"\", \$NF); print \$NF}" >> /tmp/outboxx-libs; \
    while read -r lib; do \
      mkdir -p "/runtime$(dirname "$lib")"; \
      cp -aL "$lib" "/runtime$lib"; \
    done < /tmp/outboxx-libs; \
    if [ -d /etc/ssl/certs ]; then cp -aL /etc/ssl/certs/. /runtime/etc/ssl/certs/; fi; \
    if [ -f /etc/ssl/cert.pem ]; then cp -aL /etc/ssl/cert.pem /runtime/etc/ssl/cert.pem; fi'

FROM scratch

COPY --from=builder /runtime /

USER 65532:65532
WORKDIR /app
ENTRYPOINT ["/app/outboxx"]
