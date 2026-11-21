{
  consumer,
  npmBuild,
  libraryPackage,
  sourceProvenance,
}:
{
  pkgs,
  nodejs,
  gitignore,
  root,
  self,
  src ? gitignore.gitignoreSource root,
  system ? pkgs.stdenv.hostPlatform.system,
  runtimeProviders ? null,
  buildExcludeDevDependencies ? [ ],
}:
let
  packageFile = root + /package.json;
  packageLockFile = root + /package-lock.json;
  manifest = builtins.fromJSON (builtins.readFile packageFile);
  packageLock = builtins.fromJSON (builtins.readFile packageLockFile);
  npmSources = consumer.fromLock { inherit system packageLock; };
  npmDependencies = consumer.dependencies {
    inherit
      pkgs
      nodejs
      packageLock
      npmSources
      ;
    package = manifest;
  };
  npm = consumer.install {
    inherit pkgs nodejs;
    packageName = manifest.name;
    sources = npmSources;
  };
  environment = consumer.environment { inherit pkgs nodejs npmDependencies; };
  inherit (environment) installedDependencies setupDependencies;
  buildProjection = import ../consumer/build-projection.nix {
    lib = pkgs.lib;
    package = manifest;
    inherit packageLock;
    excludeDevDependencies = buildExcludeDevDependencies;
  };
  buildSources = consumer.fromLock {
    inherit system;
    packageLock = buildProjection.packageLock;
  };
  buildDependencies =
    if buildExcludeDevDependencies == [ ] then
      npmDependencies
    else
      consumer.dependencies {
        inherit pkgs nodejs;
        inherit (buildProjection) package packageLock;
        npmSources = buildSources;
      };
  buildEnvironment =
    if buildExcludeDevDependencies == [ ] then
      environment
    else
      consumer.environment {
        inherit pkgs nodejs;
        npmDependencies = buildDependencies;
      };
  builtLibrary = npmBuild {
    inherit pkgs nodejs src;
    setupDependencies = buildEnvironment.setupDependencies;
  };
  selectedRuntimeProviders =
    if runtimeProviders != null then
      runtimeProviders
    else
      map
        (
          modulePath:
          let
            selected = npmSources.${modulePath};
          in
          {
            name = selected.archive.npmPackage.name;
            version = selected.archive.npmPackage.version;
            source = selected.source;
            archiveOutput = selected.output;
          }
        )
        (
          builtins.filter (modulePath: builtins.hasAttr modulePath npmSources) (
            map (name: "node_modules/${name}") (builtins.attrNames (manifest.dependencies or { }))
          )
        );
  npmPackage = libraryPackage {
    inherit
      pkgs
      nodejs
      src
      packageFile
      packageLockFile
      ;
    npmDependencies = buildDependencies;
    package = manifest;
    npmBuild = builtLibrary;
    sourceProvenance = sourceProvenance self;
    runtimeProviders = selectedRuntimeProviders;
  };
in
{
  inherit
    src
    npm
    npmSources
    npmDependencies
    installedDependencies
    setupDependencies
    npmPackage
    ;
  npmBuild = builtLibrary;
}
