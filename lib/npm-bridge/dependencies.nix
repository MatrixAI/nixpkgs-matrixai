{
  pkgs,
  nodejs,
  package,
  packageLock,
  npmSources,
}:
let
  # Bind the importer's node-gyp/header substitutions to the check runtime too.
  npmConfigHook =
    (pkgs.callPackage (pkgs.path + /pkgs/build-support/node/import-npm-lock/hooks) {
      inherit nodejs;
    }).npmConfigHook;
  archives = pkgs.lib.mapAttrs (_: source: source.archive) npmSources;
  unpreparedGit = pkgs.lib.filterAttrs (
    modulePath: module: pkgs.lib.hasPrefix "git" (module.resolved or "") && !(archives ? ${modulePath})
  ) packageLock.packages;
  resolveDependency =
    modulePath: name:
    let
      candidate =
        if modulePath == "" then "node_modules/${name}" else "${modulePath}/node_modules/${name}";
      parent = builtins.match "(.*)/node_modules/(@[^/]+/)?[^/]+" modulePath;
    in
    if packageLock.packages ? ${candidate} then
      candidate
    else if modulePath == "" then
      throw "Unresolved locked dependency ${name}"
    else
      resolveDependency (if parent == null then "" else builtins.head parent) name;
  normalizeEdges =
    modulePath: dependencies:
    pkgs.lib.mapAttrs (
      name: spec:
      if pkgs.lib.hasPrefix "git" spec then
        let
          target = resolveDependency modulePath name;
        in
        assert archives ? ${target};
        packageLock.packages.${target}.version
      else
        spec
    ) dependencies;
  validGitOverride =
    spec: source:
    let
      declared = builtins.match "(git[+](ssh|https|file)://[^?#]+)#semver:([~^])([0-9]+)[.]([0-9]+)[.]([0-9]+)" spec;
      resolved = builtins.match "(git[+](ssh|https|file)://[^?#]+)#([0-9a-f]{40}|[0-9a-f]{64})" source.locked.resolved;
      version = builtins.match "([0-9]+)[.]([0-9]+)[.]([0-9]+)" source.locked.version;
      number = s: builtins.fromJSON s;
      major = number (builtins.elemAt declared 3);
      minor = number (builtins.elemAt declared 4);
      patch = number (builtins.elemAt declared 5);
      actualMajor = number (builtins.elemAt version 0);
      actualMinor = number (builtins.elemAt version 1);
      actualPatch = number (builtins.elemAt version 2);
      kind = builtins.elemAt declared 2;
    in
    declared != null && resolved != null && version != null
    && builtins.elemAt declared 0 == builtins.elemAt resolved 0
    && (actualMajor > major || (actualMajor == major && (actualMinor > minor || (actualMinor == minor && actualPatch >= patch))))
    && actualMajor == major
    && (if kind == "~" then actualMinor == minor else major > 0 || (actualMinor == minor && (minor > 0 || actualPatch == patch)));
  normalizeOverrides =
    parent: overrides:
    pkgs.lib.mapAttrs (
      selector: value:
      let
        target = if selector == "." then parent else selector;
        matches = pkgs.lib.filterAttrs (
          _: source: target == source.name || pkgs.lib.hasPrefix "${source.name}@" target
        ) npmSources;
        candidates = builtins.attrValues matches;
      in
      if builtins.isAttrs value then
        normalizeOverrides target value
      else if builtins.isString value && (pkgs.lib.hasPrefix "git" value || pkgs.lib.hasPrefix "github:" value) then
        if builtins.length candidates == 1 then
          let source = builtins.head candidates; in
          if validGitOverride value source then
            "file:${source.archive}"
          else
            throw "Git override ${target} must use a supported semver range satisfied by the locked version and the same source URL"
        else
          throw "Git override ${target} requires exactly one prepared locked instance; found ${toString (builtins.length candidates)}"
      else
        value
    ) overrides;
in
assert
  unpreparedGit == { }
  || throw "Git dependencies require reviewed prepared archives: ${builtins.toJSON (builtins.attrNames unpreparedGit)}";
{
  inherit npmConfigHook;
  npmDeps = pkgs.importNpmLock {
    package = package // pkgs.lib.optionalAttrs (package ? overrides) {
      overrides = normalizeOverrides "" package.overrides;
    };
    # Source overrides invalidate any integrity belonging to the old source.
    packageLock = packageLock // {
      packages = pkgs.lib.mapAttrs (
        modulePath: module:
        (if archives ? ${modulePath} then builtins.removeAttrs module [ "integrity" ] else module)
        // pkgs.lib.optionalAttrs (module ? dependencies) {
          dependencies = normalizeEdges modulePath module.dependencies;
        }
        // pkgs.lib.optionalAttrs (module ? optionalDependencies) {
          optionalDependencies = normalizeEdges modulePath module.optionalDependencies;
        }
      ) packageLock.packages;
    };
    packageSourceOverrides = archives;
  };
}
