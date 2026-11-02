{ stdenv }:

let
  system = stdenv.hostPlatform.system;
  matrixai-lint-flake = builtins.getFlake
    "github:MatrixAI/js-lint/f52caac176676f1e781f0e4035ac8fbb0c9b2bfd";
in
matrixai-lint-flake.packages.${system}.matrixai-lint
