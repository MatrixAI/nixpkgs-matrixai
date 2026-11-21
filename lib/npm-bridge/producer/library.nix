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
}:
let
  packageFile = root + /package.json;
  packageLockFile = root + /package-lock.json;
  manifest = builtins.fromJSON (builtins.readFile packageFile);
  packageLock = builtins.fromJSON (builtins.readFile packageLockFile);
  npmSources = consumer.fromLock { inherit system packageLock; };
  npmDependencies = consumer.dependencies {
    inherit pkgs nodejs packageLock npmSources;
    package = manifest;
  };
  npm = consumer.install {
    inherit pkgs nodejs;
    packageName = manifest.name;
    sources = npmSources;
  };
  environment = consumer.environment { inherit pkgs nodejs npmDependencies; };
  inherit (environment) installedDependencies setupDependencies;
  builtLibrary = npmBuild { inherit pkgs nodejs src setupDependencies; };
  selectedRuntimeProviders =
    if runtimeProviders != null then
      runtimeProviders
    else
      map
        (modulePath:
          let
            selected = npmSources.${modulePath};
          in
          {
            name = selected.archive.npmPackage.name;
            version = selected.archive.npmPackage.version;
            source = selected.source;
            archiveOutput = selected.output;
          })
        (builtins.filter
          (modulePath:
            let
              selected = npmSources.${modulePath};
            in
            modulePath == "node_modules/${selected.name}"
            && builtins.hasAttr selected.name (manifest.dependencies or { }))
          (builtins.attrNames npmSources));
  npmPackage = libraryPackage {
    inherit
      pkgs
      nodejs
      src
      packageFile
      packageLockFile
      npmDependencies
      ;
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
