{
  lib,
  package,
  packageLock,
  excludeDevDependencies,
}:
let
  packages = packageLock.packages;
  root = packages."";
  devDependencies = package.devDependencies or { };
  excluded = excludeDevDependencies;
  requiredAtRoot =
    (package.dependencies or { })
    // (package.optionalDependencies or { })
    // (package.peerDependencies or { });
  reducedPackage = package // {
    devDependencies = builtins.removeAttrs devDependencies excluded;
  };
  reducedRoot = root // {
    devDependencies = builtins.removeAttrs (root.devDependencies or { }) excluded;
  };

  resolve =
    scope: name:
    let
      candidate = if scope == "" then "node_modules/${name}" else "${scope}/node_modules/${name}";
      parent = builtins.match "(.*)/node_modules/(@[^/]+/)?[^/]+" scope;
    in
    if builtins.hasAttr candidate packages then
      candidate
    else if scope == "" then
      null
    else
      resolve (if parent == null then "" else builtins.head parent) name;

  edges =
    scope: module:
    let
      dependencies =
        (module.dependencies or { })
        // (module.optionalDependencies or { })
        // (module.peerDependencies or { })
        // lib.optionalAttrs (scope == "") (module.devDependencies or { });
      resolveEdge =
        name:
        let
          target = resolve scope name;
          optional =
            builtins.hasAttr name (module.optionalDependencies or { })
            || lib.attrByPath [ "peerDependenciesMeta" name "optional" ] false module;
        in
        if target != null then
          target
        else if optional then
          null
        else
          throw "Cannot project build dependencies: ${scope} has unresolved dependency ${name}";
    in
    builtins.filter (entry: entry != null) (map resolveEdge (builtins.attrNames dependencies));

  walk =
    queue: seen:
    if queue == [ ] then
      seen
    else
      let
        modulePath = builtins.head queue;
        rest = builtins.tail queue;
        module = if modulePath == "" then reducedRoot else packages.${modulePath};
      in
      if builtins.hasAttr modulePath seen then
        walk rest seen
      else if module.link or false then
        throw "Cannot project build dependencies through workspace link ${modulePath}"
      else if
        builtins.any (bundled: bundled != false && bundled != [ ]) [
          (module.bundleDependencies or [ ])
          (module.bundledDependencies or [ ])
        ]
      then
        throw "Cannot project bundled dependencies for ${modulePath}"
      else
        walk (rest ++ edges modulePath module) (seen // { ${modulePath} = true; });

  visited = walk [ "" ] { };
in
assert
  packageLock.lockfileVersion == 3 || throw "Build dependency projection requires lockfile version 3";
assert
  (root.devDependencies or { }) == devDependencies
  || throw "Manifest and lockfile development dependencies differ";
assert
  builtins.all (
    name: builtins.hasAttr name devDependencies && !(builtins.hasAttr name requiredAtRoot)
  ) excluded
  || throw "Build exclusions must name development-only dependencies";
{
  package = reducedPackage;
  packageLock = packageLock // {
    packages = (lib.filterAttrs (name: _: builtins.hasAttr name visited) packages) // {
      "" = reducedRoot;
    };
  };
}
