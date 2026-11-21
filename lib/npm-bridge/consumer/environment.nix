{
  pkgs,
  nodejs,
  npmDependencies,
}:
let
  installedDependencies = pkgs.buildNpmPackage {
    pname = "library-npm-dependencies";
    version = "0";
    src = npmDependencies.npmDeps;
    inherit nodejs;
    inherit (npmDependencies) npmDeps npmConfigHook;
    dontNpmBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p "$out"
      mv node_modules "$out/node_modules"
    '';
  };
in
{
  inherit installedDependencies;
  setupDependencies = ''
    mkdir node_modules
    find ${installedDependencies}/node_modules -mindepth 1 -maxdepth 1 \
      -exec ln -s -t node_modules {} +
    export PATH="$PWD/node_modules/.bin:$PATH"
  '';
}
