{
  description = "Matrix AI Public Overlay";

  inputs = {
    # BEGIN: nixpkgs-pin (managed by scripts/nixpkgs-pin-policy.sh)
    nixpkgs = {
      type = "github";
      owner = "NixOS";
      repo = "nixpkgs";
      rev = "9ae611a455b90cf061d8f332b977e387bda8e1ca";
    };
    # END: nixpkgs-pin

    flake-parts.url = "github:hercules-ci/flake-parts";

    gitignore = {
      url = "github:hercules-ci/gitignore.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ nixpkgs, flake-parts, gitignore, ... }:
    let
      system = "x86_64-linux";

      defaultOverlay = import ./overlays;

      publicLib = import ./lib {
        lib = nixpkgs.lib;
        gitignore = gitignore.lib;
        pkgs = nixpkgs.legacyPackages.${system};
        overlay = defaultOverlay;
        mkPkgsUpstream = { system, overlays ? [ ], config ? { } }:
          import nixpkgs {
            inherit system overlays config;
          };
      };

      pkgsFor = system:
        publicLib.mkPkgs {
          inherit system;
          config.allowUnfree = true;
        };

      pkgs = pkgsFor system;

      topLevelPackages = (import ./pkgs { }).exportTopLevel pkgs;

      moduleSets = import ./modules;

      nixosModulesSet = moduleSets.nixosModules;
      homeModulesSet = moduleSets.homeModules;

      templatesOss = {
        path = ./templates/oss;
        description = "Minimal flake-parts starter consuming nixpkgs-matrixai via lib.mkPkgs";
      };

      templatesSet = {
        oss = templatesOss;
        default = templatesOss;
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ system ];

      flake = rec {
        lib = publicLib;

        overlays.default = defaultOverlay;

        legacyPackages.${system} = pkgs;

        packages.${system} = topLevelPackages;

        templates = templatesSet;

        checks.${system} = import ./checks/default.nix {
          lib = nixpkgs.lib;
          inherit
            system
            pkgs
            publicLib
            defaultOverlay
            topLevelPackages
            nixosModulesSet
            homeModulesSet
            templatesSet
            ;
          legacyPackages = pkgs;
        };

        nixosModules = nixosModulesSet;

        homeModules = homeModulesSet;
      };

      perSystem = { pkgs, ... }: {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.nix
            pkgs.git
            pkgs.jq
            pkgs.gnugrep
            pkgs.gawk
            pkgs.coreutils
            pkgs.gnused
            pkgs.findutils
            pkgs.curl
            pkgs.wget
          ];
        };
      };
    };
}
