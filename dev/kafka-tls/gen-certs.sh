#!/usr/bin/env bash
# Generate self-signed TLS material for the local/CI Kafka broker.
#
# These are throwaway test certificates, never committed (see .gitignore) and never
# used in production. In CI the same files come from GitHub Actions secrets instead.
#
# Outputs into dev/kafka-tls/certs/ (bitnami PEM layout is three separate files):
#   kafka.keystore.pem   - server certificate
#   kafka.keystore.key   - server private key
#   kafka.truststore.pem - CA cert
#   ca.crt               - CA cert for the client (ssl.ca.location)
set -euo pipefail

certs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certs"
mkdir -p "$certs_dir"

if [[ -f "$certs_dir/kafka.keystore.pem" ]]; then
  echo "Certs already present in $certs_dir (delete to regenerate)."
  exit 0
fi

echo "Generating self-signed test certs into $certs_dir ..."
days=36500 # ~100y so test certs never expire

# Self-signed CA.
openssl req -x509 -newkey rsa:2048 -sha256 -days "$days" -nodes \
  -keyout "$certs_dir/ca.key" -out "$certs_dir/ca.crt" \
  -subj "/CN=outboxx-test-ca"

# Server key + CSR, signed by the CA with SAN for localhost and the compose hostname.
ext_file="$(mktemp)"
printf "subjectAltName=DNS:localhost,DNS:kafka\n" >"$ext_file"

openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout "$certs_dir/server.key" -out "$certs_dir/server.csr" \
  -subj "/CN=localhost"

openssl x509 -req -in "$certs_dir/server.csr" \
  -CA "$certs_dir/ca.crt" -CAkey "$certs_dir/ca.key" -CAcreateserial \
  -out "$certs_dir/server.crt" -days "$days" -sha256 -extfile "$ext_file"

rm -f "$ext_file"

# bitnami PEM layout: server cert, server key and CA as three separate files.
cp "$certs_dir/server.crt" "$certs_dir/kafka.keystore.pem"
cp "$certs_dir/server.key" "$certs_dir/kafka.keystore.key"
cp "$certs_dir/ca.crt" "$certs_dir/kafka.truststore.pem"

# Bind-mounted into a container that runs as a non-root user; keep them world-readable
# (test-only material, no secrecy needed).
chmod 644 "$certs_dir"/*.pem "$certs_dir"/*.key "$certs_dir/ca.crt"

echo "Done."
