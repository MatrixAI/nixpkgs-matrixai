{ stdenv }:

let
  system = stdenv.hostPlatform.system;
  matrixai-lint-flake = builtins.getFlake
    "github:MatrixAI/js-lint/b380232a895dcee9a05ee06284952563928ade41";
in
matrixai-lint-flake.packages.${system}.matrixai-lint
