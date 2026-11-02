{ }:

let
  registry = {
    topLevel = {
      matrixai-lint = ./top-level/matrixai-lint.nix;
      matrixai-public-hello = ./top-level/matrixai-public-hello.nix;
      polykey-cli = ./top-level/polykey-cli.nix;
      structured-madr = ./top-level/structured-madr;
      vl-convert = ./top-level/vl-convert;
    };

    scopes = {
      python3Packages = {
        jsonpyth = ./development/python-modules/jsonpyth;
        procpath = ./development/python-modules/procpath;
      };
    };
  };

  loadDefs = pkgSet: defs:
    builtins.mapAttrs (_: path: pkgSet.callPackage path { }) defs;

  topLevelNames = builtins.attrNames registry.topLevel;
in {
  exportTopLevel = pkgs:
    builtins.listToAttrs (map
      (name: {
        inherit name;
        value = pkgs.${name};
      })
      topLevelNames);

  overlay = final: prev:
    loadDefs final registry.topLevel
    // builtins.mapAttrs
      (scopeName: defs:
        prev.${scopeName}.overrideScope
          (scopeFinal: _scopePrev: loadDefs scopeFinal defs))
      registry.scopes;
}
