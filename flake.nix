{
  description = "Outboxx - PostgreSQL Change Data Capture tool written in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Zig compiler
            zig

            # C libraries for Outboxx
            postgresql        # PostgreSQL client library and headers
            rdkafka           # Apache Kafka C client (librdkafka)
            pkg-config        # For finding libraries

            # Development tools
            docker-compose
            gnumake
            coreutils         # Basic shell utilities
            which             # Command location utility
          ];

          # Environment variables for proper library linking
          shellHook = ''
            # Fix user environment variables to avoid "I have no name!" issue
            export USER=''${USER:-$(whoami 2>/dev/null || echo "developer")}
            export USERNAME=$USER
            export HOME=''${HOME:-/tmp}

            # Set a proper bash prompt
            export PS1="\[\033[01;32m\]$USER@nix-shell\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "

            echo "Outboxx development environment activated!"
            echo "Welcome, $USER!"
            echo ""
            echo "Available libraries:"
            echo "  - libpq (PostgreSQL): ${pkgs.postgresql}/lib"
            echo "  - librdkafka (Kafka): ${pkgs.rdkafka}/lib"
            echo ""
            echo "Library paths configured for Zig build system"

            # Set environment variables for Zig to find libraries
            export LIBRARY_PATH="${pkgs.postgresql}/lib:${pkgs.rdkafka}/lib:$LIBRARY_PATH"
            export C_INCLUDE_PATH="${pkgs.postgresql}/include:${pkgs.rdkafka}/include:$C_INCLUDE_PATH"
            export PKG_CONFIG_PATH="${pkgs.postgresql}/lib/pkgconfig:${pkgs.rdkafka}/lib/pkgconfig:$PKG_CONFIG_PATH"

            # Convenient aliases
            alias zigrun="zig build run"
            alias zigtest="zig build test"
            alias zigfmt="zig build fmt"
          '';
        };
      });
}