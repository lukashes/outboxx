{
  description = "Outboxx - PostgreSQL Change Data Capture tool written in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Static (musl) C dependencies for the release binaries. Pinned separately
    # so bumping it can never move the dev toolchain (zig) underneath us.
    nixpkgs-static.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, nixpkgs-static, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Override rdkafka to use latest version for performance improvements
        # v2.12.1 includes important latency fixes:
        # - Fixed 1s delay for first message in producev/produceva
        # - TCP_NODELAY enabled by default (lower latency)
        # - Removed 500ms latency on partition leader switch
        rdkafka-latest = pkgs.rdkafka.overrideAttrs (old: rec {
          version = "2.12.1";
          src = pkgs.fetchFromGitHub {
            owner = "confluentinc";
            repo = "librdkafka";
            rev = "v${version}";
            sha256 = "sha256-BqATSZgAYIfIGt9OMXN6UYkFW7fQH4ifyaz3gTVmUso=";
          };
        });
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            # Zig toolchain
            zig
            zls                # Zig Language Server

            # Build tools
            pkg-config
            gnumake
          ];

          buildInputs = with pkgs; [
            # C libraries
            postgresql         # PostgreSQL client library
            rdkafka-latest    # Apache Kafka C client (v2.12.1 with performance fixes)

            # Development tools
            docker-compose

            # Profiling tools (for flamegraph generation)
            flamegraph          # FlameGraph scripts
          ];

          shellHook = ''
            # Only set C_INCLUDE_PATH for header files (used by build.zig).
            # Use the `dev` outputs: the default (`out`) outputs contain no headers,
            # which breaks the build-system translate-c step (it only honors -I,
            # unlike @cImport which also reads NIX_CFLAGS_COMPILE).
            export C_INCLUDE_PATH="${pkgs.postgresql.dev}/include:${rdkafka-latest.dev}/include:''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"

            echo "Outboxx development environment ready"
          '';
        };
      }
      # Static (musl) archives for the portable release binaries, merged into
      # one prefix: zig build takes it via --search-prefix (lib/) and the
      # translate-c step via C_INCLUDE_PATH (include/). Linux only: pkgsStatic
      # targets static darwin on macOS, which is neither supported nor needed.
      // nixpkgs.lib.optionalAttrs (pkgs.stdenv.isLinux) (
        let
          spkgs = nixpkgs-static.legacyPackages.${system};
          st = spkgs.pkgsStatic;
          # No curl (only used for OAuth OIDC token fetch) and no cyrus-sasl
          # (only adds GSSAPI; its mechanisms are dlopen plugins, useless in a
          # static binary). TLS and the builtin SCRAM/PLAIN stay in.
          rdkafka-lean = (st.rdkafka.override { curl = null; cyrus_sasl = null; }).overrideAttrs (o: {
            cmakeFlags = o.cmakeFlags ++ [ "-DWITH_CURL=OFF" "-DWITH_SASL=OFF" "-DWITH_OAUTHBEARER_OIDC=OFF" ];
            # Upstream bug: config.h.in uses cmakedefine01 (macro always
            # defined, as 0 or 1) but the sources guard with #ifdef, so an
            # OFF build still tries to include curl.h.
            postPatch = (o.postPatch or "") + ''
              sed -i "s/#ifdef WITH_OAUTHBEARER_OIDC/#if WITH_OAUTHBEARER_OIDC/" src/*.c src/*.h
            '';
          });
        in
        {
          packages.static-deps = spkgs.symlinkJoin {
            name = "outboxx-static-deps";
            paths = [
              st.libpq.dev # the .a files live in the dev output on static builds
              rdkafka-lean
              rdkafka-lean.dev
              st.openssl.out
              (st.zlib.static or st.zlib)
              st.zstd.out
            ];
          };
        }
      ));
}
