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
            # Only set C_INCLUDE_PATH for header files (used by build.zig)
            export C_INCLUDE_PATH="${pkgs.postgresql}/include:${pkgs.rdkafka}/include:''${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"

            echo "Outboxx development environment ready"
          '';
        };
      });
}