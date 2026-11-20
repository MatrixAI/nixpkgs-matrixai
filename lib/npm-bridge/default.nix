{ }:
let
  sources = import ./sources.nix;
  selectionsFromLock =
    {
      packageLock,
      include ? (name: builtins.match "@matrixai/[^/]+" name != null),
    }:
    let
      entry = modulePath:
        let
          match = builtins.match "(.*/)?node_modules/(@[^/]+/)?([^/]+)" modulePath;
          scope = if match == null || builtins.elemAt match 1 == null then "" else builtins.elemAt match 1;
          name = if match == null then "" else scope + builtins.elemAt match 2;
          resolved = packageLock.packages.${modulePath}.resolved or "";
        in
        if match != null && builtins.isString resolved && builtins.match "git[+]ssh://[^?#]+#[0-9a-f]{40}" resolved != null && include name then
          { name = modulePath; value = { inherit name; }; }
        else
          null;
    in
    builtins.listToAttrs (builtins.filter (value: value != null) (map entry (builtins.attrNames packageLock.packages)));
  fromLock = { system, packageLock, include ? (name: builtins.match "@matrixai/[^/]+" name != null), selections ? { } }:
    sources {
      inherit system packageLock;
      selections = (selectionsFromLock { inherit packageLock include; }) // selections;
    };
  dependencies = import ./dependencies.nix;
in
{
  inherit sources selectionsFromLock fromLock dependencies;
  dependenciesFromRoot = { pkgs, nodejs, root, system ? pkgs.stdenv.hostPlatform.system }:
    let
      package = builtins.fromJSON (builtins.readFile (root + /package.json));
      packageLock = builtins.fromJSON (builtins.readFile (root + /package-lock.json));
      npmSources = fromLock { inherit system packageLock; };
    in
    dependencies { inherit pkgs nodejs package packageLock npmSources; };
  install = import ./install.nix;
}
