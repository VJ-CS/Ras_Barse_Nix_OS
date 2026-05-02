{
  description = "Flake: NixOS image for Raspberry Pi 400 appliance (aarch64) - production grade";

  inputs = {
    # Stable, pinned nixpkgs release for reproducibility
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";

    # Utilities for multi-system outputs
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        # Path to the NixOS configuration module for the device
        configFile = ./configuration.nix;

        # Build a NixOS system configuration object
        nixosConf = pkgs.lib.nixosSystem {
          inherit system;
          modules = [ configFile ];
        };
      in
      {
        # Expose a simple package for quick smoke tests
        packages.default = pkgs.hello;

        # Primary NixOS configuration for the Raspberry Pi 400
        nixosConfigurations.rpi400 = nixosConf;

        # Expose the sdImage build artifact for CI (GitHub Actions)
        packages.sdImage = nixosConf.config.system.build.sdImage;
      }
    );
}
