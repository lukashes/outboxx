{
  description = "Outboxx - PostgreSQL Change Data Capture tool written in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
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
            # Only set C_INCLUDE_PATH for header files (used by build.zig)
            export C_INCLUDE_PATH="${pkgs.postgresql}/include:${rdkafka-latest}/include:''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"

            echo "Outboxx development environment ready"
          '';
        };
      });
}
