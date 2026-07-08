FROM nixos/nix:2.24.10 AS builder

ARG VERSION=0.2.0

RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

WORKDIR /src

# Cache the Nix build environment before copying the full repository.
COPY flake.nix flake.lock ./
RUN nix develop --command echo "deps cached"

COPY . .
RUN nix develop --command zig build -Dcpu=baseline -Doptimize=ReleaseFast -Dversion="${VERSION}"
RUN nix develop --command bash -c 'set -euo pipefail; \
    mkdir -p /runtime/app /runtime/etc/ssl/certs /runtime/etc; \
    cp zig-out/bin/outboxx /runtime/app/outboxx; \
    ldd zig-out/bin/outboxx | \
      awk "/=> \/nix\/store/ {print \$(NF-1)} /^\/nix\/store/ {print \$1}" | \
      sort -u > /tmp/outboxx-libs; \
    interpreter="$(readelf -l zig-out/bin/outboxx | awk "/Requesting program interpreter/ {gsub(/[][]/, \"\", \$NF); print \$NF}")"; \
    if [ -n "$interpreter" ]; then echo "$interpreter" >> /tmp/outboxx-libs; fi; \
    libc="$(awk "/\/libc\\.so\\.6$/ {print; exit}" /tmp/outboxx-libs)"; \
    if [ -n "$libc" ]; then \
      libc_dir="$(dirname "$libc")"; \
      for nss_lib in libnss_dns.so.2 libnss_files.so.2 libresolv.so.2; do \
        if [ -e "$libc_dir/$nss_lib" ]; then echo "$libc_dir/$nss_lib" >> /tmp/outboxx-libs; fi; \
      done; \
    fi; \
    sort -u /tmp/outboxx-libs | while read -r lib; do \
      mkdir -p "/runtime$(dirname "$lib")"; \
      cp -aL "$lib" "/runtime$lib"; \
    done; \
    printf "hosts: files dns\npasswd: files\ngroup: files\n" > /runtime/etc/nsswitch.conf; \
    if [ -d /etc/ssl/certs ]; then cp -aL /etc/ssl/certs/. /runtime/etc/ssl/certs/; fi; \
    if [ -f /etc/ssl/cert.pem ]; then cp -aL /etc/ssl/cert.pem /runtime/etc/ssl/cert.pem; fi'

FROM nixos/nix:2.24.10

COPY --from=builder /runtime /

RUN rm -rf /root/.cache /tmp/* /var/tmp/* /nix/var/nix/gcroots/auto/* /nix/var/nix/profiles/per-user/root/channels

USER 65532:65532
WORKDIR /app
ENTRYPOINT ["/app/outboxx"]
