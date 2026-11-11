{ stdenv }:

let
  system = stdenv.hostPlatform.system;
  matrixai-lint-flake = builtins.getFlake
    "github:MatrixAI/js-lint/edfac397ab407c71306b372eae863b9c8dd10fb7";
in
matrixai-lint-flake.packages.${system}.matrixai-lint
