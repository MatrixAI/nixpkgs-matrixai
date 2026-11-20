/*
  Construct the library scope.

  Signature:

    { lib
    , gitignore
    , pkgs
    , overlay
    , mkPkgsUpstream
    } -> lib

  Construction-time arguments:
    lib:
      Upstream nixpkgs lib.

    gitignore:
      Library helpers from hercules-ci/gitignore.nix.

    pkgs:
      Base package set used for dependency injection when loading library files.

    overlay:
      Default overlay forwarded to `mkPkgs`.

    mkPkgsUpstream:
      Upstream package-set constructor forwarded to `mkPkgs`.

  Result:
    A scoped helper attrset that exports:

      lib:
        The upstream nixpkgs lib, preserved under the public scope.

      gitignore:
        Source filtering helpers from hercules-ci/gitignore.nix.

      callLib:
        Explicit dependency-injection entrypoint for repository library helpers.

      mkPkgs:
        Canonical package-set constructor built through `callLib`.

      Other library functions...
*/

{ lib
, gitignore
, pkgs
, overlay
, mkPkgsUpstream
}:

lib.makeScope lib.callPackageWith (self: {
  inherit gitignore lib;

  # Explicit DI entrypoint for library files
  callLib = lib.callPackageWith ((pkgs // self) // { inherit lib; });

  mkPkgs = self.callLib ./mkPkgs.nix {
    inherit overlay mkPkgsUpstream;
  };

  npmBridge = self.callLib ./npm-bridge { };
})
