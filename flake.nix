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
            rdkafka           # Apache Kafka C client

            # Development tools
            docker-compose
          ];

          shellHook = ''
            # Set environment variables for Zig to find libraries
            export LIBRARY_PATH="${pkgs.postgresql}/lib:${pkgs.rdkafka}/lib:''${LIBRARY_PATH:+:$LIBRARY_PATH}"
            export C_INCLUDE_PATH="${pkgs.postgresql}/include:${pkgs.rdkafka}/include:''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
            export PKG_CONFIG_PATH="${pkgs.postgresql}/lib/pkgconfig:${pkgs.rdkafka}/lib/pkgconfig:''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

            echo "Outboxx development environment ready"
          '';
        };
      });
}