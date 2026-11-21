{
  pkgs,
  nodejs,
  src,
  package,
  packageFile,
  packageLockFile,
  npmDependencies,
  npmBuild,
  sourceProvenance,
  runtimeProviders ? [ ],
}:
let
  pname = builtins.replaceStrings [ "@" "/" ] [ "" "-" ] package.name;
  needsBundledDependencies = builtins.any (bundled: bundled != false && bundled != [ ]) [
    (package.bundleDependencies or [ ])
    (package.bundledDependencies or [ ])
  ];
  mkPackage = if needsBundledDependencies then pkgs.buildNpmPackage else pkgs.stdenvNoCC.mkDerivation;
in
mkPackage (
  {
    inherit pname src nodejs;
    version = package.version;
    name = "${pname}-${package.version}.tgz";
    outputs = [
      "out"
      "unpacked"
    ];
    nativeBuildInputs = [ nodejs ];
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      cmp package.json ${packageFile}
      cmp package-lock.json ${packageLockFile}
      cp -R ${npmBuild}/dist dist
      mkdir -p "$TMPDIR/npm-pack" "$unpacked"
      npm_config_cache="$TMPDIR/npm-pack-cache" \
        npm pack --offline --ignore-scripts --pack-destination "$TMPDIR/npm-pack"
      archives=("$TMPDIR/npm-pack"/*.tgz)
      test "''${#archives[@]}" -eq 1
      mv "''${archives[0]}" "$out"
      tar -xzf "$out" -C "$unpacked" --strip-components=1
      cmp "$unpacked/package.json" ${packageFile}
      runHook postInstall
    '';
    dontFixup = true;
    passthru = {
      npmPackage = {
        schemaVersion = 1;
        format = "npm-tgz";
        inherit (package) name version;
        dependencies = package.dependencies or { };
        peerDependencies = package.peerDependencies or { };
        peerDependenciesMeta = package.peerDependenciesMeta or { };
        optionalDependencies = package.optionalDependencies or { };
        engines = package.engines or { };
        bin = package.bin or { };
        source = sourceProvenance;
      };
      npmDistribution = {
        schemaVersion = 1;
        archiveOutput = "npm-package";
        inherit runtimeProviders;
      };
    };
    meta = {
      description = package.description;
      license =
        if package.license == "UNLICENSED" then
          pkgs.lib.licenses.unfree
        else
          pkgs.lib.meta.getLicenseFromSpdxId package.license;
      outputsToInstall = [ "out" ];
    };
  }
  // pkgs.lib.optionalAttrs needsBundledDependencies {
    inherit (npmDependencies) npmDeps npmConfigHook;
    dontNpmBuild = true;
  }
)
