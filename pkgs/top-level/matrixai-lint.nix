{ stdenv }:

let
  system = stdenv.hostPlatform.system;
  matrixai-lint-flake = builtins.getFlake
    "github:MatrixAI/js-lint/f2a3ef1be411cedc47794577156f007292eec87a";
in
matrixai-lint-flake.packages.${system}.matrixai-lint
